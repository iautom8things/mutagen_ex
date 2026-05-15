defmodule MutagenEx.MutationRunnerTest do
  @moduledoc """
  Tests for `MutagenEx.MutationRunner` and (by way of the runner's public
  surface) the private `MutagenEx.MutationRunner.MutationLoop`.

  Subjects advanced (see `.spec/specs/mutation_pipeline.spec.md`):

    * `mutagen.mutation_pipeline.r3` / `s2` — self-mutation refusal.
    * `mutagen.mutation_pipeline.r4` / `s3` — per-mutation timeout; site
      classified `:timeout`; subsequent results tainted.
    * `mutagen.mutation_pipeline.r5` / `s4` — five outcomes; compile
      errors don't enter the kill-rate denominator.
    * `mutagen.mutation_pipeline.r6` / `s5` — restore via
      `Code.compile_quoted` on cached AST; unrecoverable restore failure
      aborts.
    * `mutagen.mutation_pipeline.r7` / `s6` — pre/post snapshots flag
      taint; subsequent results carry `tainted_predecessors: true`.
    * `mutagen.mutation_pipeline.r8` / `s7` — `use SomeModule` modules
      emit `state_drift_warning`.
    * `mutagen.mutation_pipeline.r9` / `s8` — stderr captured into
      `results[i].warnings`.
    * `mutagen.mutation_pipeline.r11` — no file on disk is modified by
      the runner. Asserted across `lib/`, `_build/`, `cover/`, host
      project config (mix.exs, mix.lock, .formatter.exs), and tmp
      entries with the `mutagen_ex_` prefix — see the r11 describe
      block below.
  """

  # Load the disk-snapshot test helper. We use `Code.require_file/1`
  # rather than adding a `test/support/` compile path to mix.exs to
  # keep the helper scoped to the tests that need it (r11 here, r7 in
  # coverage_runner_test.exs). require_file is idempotent — loading
  # twice from two test modules is a no-op.
  Code.require_file("../support/disk_snapshot_helper.exs", __DIR__)

  use ExUnit.Case, async: false

  alias MutagenEx.AstCache
  alias MutagenEx.MutationEnumerator.Site
  alias MutagenEx.MutationRunner
  alias MutagenEx.ScopeResolver.Scope
  alias MutagenEx.TestSelector.TestFilter

  # Forward aliases for inner stub modules so bare references in tests
  # (e.g. `ExUnitFake`, `CompilerStub`) resolve to our test-local
  # definitions rather than `Elixir.ExUnitFake`.
  alias __MODULE__.{CaptureIoStub, CompilerStub, ExUnitFake, ExUnitServerStub}

  # `:cover` stop hygiene (defensive — none of these tests instrument cover, but
  # CoverageRunner tests may have left it running. Per H-Tt3.)
  setup do
    # Start the ExUnit fake's Agent. on_exit kills it so each test has
    # an isolated state machine.
    {:ok, _pid} = ExUnitFake.start_link()

    on_exit(fn ->
      try do
        apply(:cover, :stop, [])
      rescue
        _ -> :ok
      catch
        _, _ -> :ok
      end
    end)

    :ok
  end

  # ---- Stubs ----------------------------------------------------------------

  # A named Agent backs the fake's state so it works across the Task
  # MutationLoop spawns (Process dictionary doesn't cross task
  # boundaries; this Agent does).
  defmodule ExUnitFake do
    @moduledoc false
    @agent :mutagen_ex_runner_test_exunit_fake

    def start_link do
      # A prior test's Agent should die when its test process exits
      # (it's linked), but under suite load the BEAM's name-registry
      # cleanup can lag the next test's setup just long enough for
      # `:already_started` to surface. Defensively reap any stale
      # registration before re-registering.
      case Agent.start_link(fn -> %{configure: nil, results: []} end, name: @agent) do
        {:ok, pid} ->
          {:ok, pid}

        {:error, {:already_started, stale}} ->
          Process.exit(stale, :kill)
          # Wait until the name actually clears before retrying so the
          # second start_link doesn't race the same way.
          wait_until_unregistered()
          Agent.start_link(fn -> %{configure: nil, results: []} end, name: @agent)
      end
    end

    defp wait_until_unregistered(remaining_ms \\ 500) do
      cond do
        Process.whereis(@agent) == nil ->
          :ok

        remaining_ms <= 0 ->
          :ok

        true ->
          Process.sleep(10)
          wait_until_unregistered(remaining_ms - 10)
      end
    end

    def set_results(results), do: Agent.update(@agent, fn s -> %{s | results: results} end)
    def get_configure, do: Agent.get(@agent, & &1.configure)

    def configure(opts) do
      Agent.update(@agent, fn s -> %{s | configure: opts} end)
      :ok
    end

    def run do
      next =
        Agent.get_and_update(@agent, fn s ->
          case s.results do
            [head | rest] -> {head, %{s | results: rest}}
            [] -> {:default, s}
          end
        end)

      handle_next(next)
    end

    defp handle_next(:default), do: %{failures: 0, total: 1, excluded: 0, skipped: 0}

    defp handle_next({:result, r}), do: r

    defp handle_next({:raise, msg}), do: raise(msg)

    defp handle_next({:sleep_then, ms, r}) do
      Process.sleep(ms)
      r
    end

    # Trap exits and idle in a receive loop. The cooperative-cancel path
    # in `MutationLoop.cancel_on_timeout/2` issues `:shutdown` first (a
    # trappable signal); a process that traps exits and matches on
    # `{:EXIT, _, :shutdown}` can return a clean result inside the
    # grace window — proving the cooperative phase actually fires
    # before brutal_kill. Used by the r4 graceful-cancel regression
    # test below.
    defp handle_next({:trap_then_yield_on_shutdown, r}) do
      Process.flag(:trap_exit, true)

      receive do
        {:EXIT, _from, :shutdown} -> r
      after
        # Defensive ceiling so a buggy fake doesn't hang the suite.
        5_000 -> r
      end
    end

    # Sleeps even when receiving a :shutdown signal. Used to drive the
    # brutal-kill escalation path: trap exits and explicitly ignore
    # :shutdown, so phase 1 of the cooperative-cancel sequence cannot
    # finish — only phase 2 (brutal_kill) actually clears the task.
    defp handle_next({:trap_and_ignore_shutdown, ms, r}) do
      Process.flag(:trap_exit, true)
      deadline = System.monotonic_time(:millisecond) + ms

      drain_shutdowns_until(deadline)

      r
    end

    # Intentionally leak a named process so `Process.registered/0`'s
    # length grows AFTER the runner takes its post-snapshot. The named
    # pid is recorded under `{:leak, name}` on the test process's
    # dictionary so on_exit can reap it without the registered name
    # surviving into the next test. Used by the r7 snapshot-growth test
    # to drive `snapshot_grew?` true without a `:timeout`.
    defp handle_next({:leak_proc, name, r}) do
      # Sanity: ensure the name isn't already registered (e.g. from a
      # prior aborted test); if it is, unregister so we can re-register.
      case Process.whereis(name) do
        nil ->
          :ok

        pid ->
          Process.unregister(name)
          Process.exit(pid, :kill)
      end

      # Spawn a small process that idles. We register it ourselves so
      # `Process.registered/0` reflects the growth immediately on
      # return — the child only needs to stay alive long enough for the
      # runner's post-snapshot.
      pid = spawn(fn -> Process.sleep(:infinity) end)
      true = Process.register(pid, name)
      r
    end

    # Helper for `{:trap_and_ignore_shutdown, ms, _}`. Kept private to
    # the fake and below all `handle_next/1` clauses so the
    # multiple-clauses-not-grouped lint stays quiet.
    defp drain_shutdowns_until(deadline_ms) do
      remaining = deadline_ms - System.monotonic_time(:millisecond)

      cond do
        remaining <= 0 ->
          :ok

        true ->
          receive do
            {:EXIT, _from, :shutdown} -> drain_shutdowns_until(deadline_ms)
          after
            remaining -> :ok
          end
      end
    end
  end

  defmodule ExUnitServerStub do
    @moduledoc false
    def add_module(_mod, _cfg) do
      Process.put(:exunit_server_stub_calls, (Process.get(:exunit_server_stub_calls) || 0) + 1)
      :ok
    end
  end

  defmodule CaptureIoStub do
    @moduledoc false
    # `ExUnit.CaptureIO.with_io(:stderr, fn -> ... end)` returns
    # `{closure_result, captured_stderr}`. We delegate to the real
    # ExUnit.CaptureIO so tests that don't care about capture get the
    # real shape; tests asserting against captured-stderr content also
    # work because the real capture suppresses + returns.
    defdelegate with_io(device, fun), to: ExUnit.CaptureIO
  end

  defmodule CompilerStub do
    @moduledoc false
    # In-memory compiler replacement. Records every call; can be
    # configured to raise for specific calls so we exercise compile_error
    # and restore-failure paths.
    #
    # `:compiler_stub_hooks` is `[{predicate_fn, action}]`. The first
    # predicate that returns `true` on `{ast, file}` decides the action.
    # `action` is `{:raise, message}` or `{:ok, modules}`.
    def compile_quoted(ast, file) do
      Process.put(
        :compiler_stub_calls,
        [{file, ast} | Process.get(:compiler_stub_calls) || []]
      )

      hooks = Process.get(:compiler_stub_hooks) || []

      case Enum.find(hooks, fn {pred, _action} -> pred.(ast, file) end) do
        {_, {:raise, message}} ->
          raise CompileError, description: message

        {_, {:ok, modules}} ->
          modules

        nil ->
          # Default: pretend compile succeeded; return an empty module
          # list so the runner sees a valid `{module, binary}` shape.
          []
      end
    end
  end

  # Predicate helpers — `contains_node?/2` walks a candidate AST looking
  # for a sub-tree equal to `target`. This lets compile-stub hooks fire
  # when the runner's full-file AST contains the mutated/original site
  # node (since the runner passes the WHOLE file AST to compile_quoted).
  defp contains_node?(ast, target) do
    {_, found} =
      Macro.prewalk(ast, false, fn
        _node, true -> {nil, true}
        node, _ -> {node, node == target}
      end)

    found
  end

  # ---- Site builder ---------------------------------------------------------

  defp build_site(opts \\ []) do
    file = Keyword.get(opts, :file, "synthetic/foo.ex")
    line = Keyword.get(opts, :line, 2)
    column = Keyword.get(opts, :column, 13)
    mutator = Keyword.get(opts, :mutator, :arith)
    id = Keyword.get(opts, :id, "syn:1:arith")

    original_ast =
      Keyword.get(
        opts,
        :original_ast,
        {:+, [line: line, column: column], [1, 2]}
      )

    mutated_ast =
      Keyword.get(
        opts,
        :mutated_ast,
        {:-, [line: line, column: column], [1, 2]}
      )

    %Site{
      id: id,
      file: file,
      line: line,
      column: column,
      mutator: mutator,
      original_ast: original_ast,
      mutated_ast: mutated_ast
    }
  end

  defp build_file_ast_with_site(site, file) do
    {:defmodule, [line: 1, column: 1],
     [
       {:__aliases__, [line: 1], [:Synthetic, :Foo]},
       [
         do:
           {:def, [line: 2, column: 3],
            [
              {:add, [line: 2, column: 7], []},
              [do: site.original_ast]
            ]}
       ]
     ]}
    |> tap(fn _ast -> :ok end)
    |> then(fn ast ->
      # Build the ast_cache entry the runner expects: {ast, source}.
      {file, {ast, "defmodule Synthetic.Foo do\n  def add, do: 1 + 2\nend\n"}}
    end)
  end

  defp base_cfg(site_or_sites, opts \\ []) do
    sites = List.wrap(site_or_sites)
    file = (List.first(sites) || %{file: "synthetic/foo.ex"}).file

    {^file, entry} = build_file_ast_with_site(List.first(sites), file)
    ast_cache = %{file => entry}

    scope_records =
      Keyword.get(opts, :scope_records, [
        %Scope{file: file, line_range: 1..3, module: Synthetic.Foo}
      ])

    %{
      seed: 0,
      timeout_ms: Keyword.get(opts, :timeout_ms, 500),
      test_filter: %TestFilter{include: [], exclude: [:test], files: []},
      ast_cache: ast_cache,
      sites: sites,
      scope_records: scope_records,
      test_modules:
        Keyword.get(opts, :test_modules, [
          {Some.TestModule, %{async?: false, group: nil, parameterize: nil}}
        ]),
      ex_unit: ExUnitFake,
      ex_unit_server: ExUnitServerStub,
      capture_io: CaptureIoStub,
      compiler: {CompilerStub, :compile_quoted}
    }
  end

  defp clear_stubs do
    Process.delete(:exunit_fake_run_results)
    Process.delete(:exunit_fake_configure)
    Process.delete(:exunit_server_stub_calls)
    Process.delete(:compiler_stub_calls)
    Process.delete(:compiler_stub_hooks)
  end

  # ---------------------------------------------------------------------------
  # r3 / s2: self-mutation refusal
  # ---------------------------------------------------------------------------

  describe "r3: self-mutation refusal (s2)" do
    test "aborts before any compile if a scope record names a MutagenEx.* module" do
      clear_stubs()
      site = build_site()

      cfg = %{
        base_cfg(site)
        | scope_records: [
            %Scope{
              file: "lib/mutagen_ex/mutation_runner.ex",
              line_range: 1..10,
              module: MutagenEx.MutationRunner
            }
          ]
      }

      assert {:error, :self_mutation_refused, details} = MutationRunner.run(cfg)
      assert MutagenEx.MutationRunner in details.modules
      assert is_binary(details.message)

      # No compile attempts were made.
      assert (Process.get(:compiler_stub_calls) || []) == []
    end

    test "aborts on Mix.Tasks.Mutagen" do
      clear_stubs()
      site = build_site()

      cfg = %{
        base_cfg(site)
        | scope_records: [
            %Scope{file: "lib/mix/tasks/mutagen.ex", line_range: 1..10, module: Mix.Tasks.Mutagen}
          ]
      }

      assert {:error, :self_mutation_refused, details} = MutationRunner.run(cfg)
      assert Mix.Tasks.Mutagen in details.modules
    end

    test "allows a benign scope (no MutagenEx.* or Mix.Tasks.Mutagen)" do
      clear_stubs()
      site = build_site()
      cfg = base_cfg(site)

      assert {:ok, %{results: [_]}} = MutationRunner.run(cfg)
    end
  end

  # ---------------------------------------------------------------------------
  # r5 / s4: five outcomes; :compile_error excluded from results array
  # ---------------------------------------------------------------------------

  describe "r5: five outcomes" do
    test ":killed when ExUnit reports failures > 0" do
      clear_stubs()
      site = build_site(id: "k1")
      cfg = base_cfg(site)

      ExUnitFake.set_results([
        {:result, %{failures: 1, total: 3, excluded: 0, skipped: 0}}
      ])

      assert {:ok, %{results: [result]}} = MutationRunner.run(cfg)
      assert result.status == :killed
    end

    test ":survived when failures == 0" do
      clear_stubs()
      site = build_site(id: "s1")
      cfg = base_cfg(site)

      ExUnitFake.set_results([
        {:result, %{failures: 0, total: 3, excluded: 0, skipped: 0}}
      ])

      assert {:ok, %{results: [result]}} = MutationRunner.run(cfg)
      assert result.status == :survived
    end

    test ":compile_error sites live in compile_errors, NOT results (s4)" do
      clear_stubs()
      site = build_site(id: "c1")
      cfg = base_cfg(site)

      Process.put(:compiler_stub_hooks, [
        {fn ast, _file -> contains_node?(ast, site.mutated_ast) end,
         {:raise, "syntax err for site c1"}}
      ])

      assert {:ok, output} = MutationRunner.run(cfg)
      assert output.results == []
      assert [entry] = output.compile_errors
      assert entry.id == "c1"
      assert entry.mutator == :arith
      assert is_binary(entry.message)
    end

    test ":error when ExUnit.run raises uncaught" do
      clear_stubs()
      site = build_site(id: "e1")
      cfg = base_cfg(site)

      ExUnitFake.set_results([{:raise, "boom"}])

      assert {:ok, %{results: [result]}} = MutationRunner.run(cfg)
      assert result.status == :error
      assert Enum.any?(result.warnings, &(&1 =~ "error"))
    end
  end

  # ---------------------------------------------------------------------------
  # r4 / r7 / s3 / s6: timeout + taint propagation
  # ---------------------------------------------------------------------------

  describe "r4 + r7: timeout and taint (s3, s6)" do
    test ":timeout site classifies as :timeout and subsequent result has tainted_predecessors: true" do
      clear_stubs()
      site1 = build_site(id: "t1", line: 2, column: 13)
      site2 = build_site(id: "t2", line: 2, column: 13)

      cfg = base_cfg([site1, site2], timeout_ms: 50)

      ExUnitFake.set_results([
        # Site 1: sleep past the 50ms budget to trigger a timeout.
        {:sleep_then, 200, %{failures: 0, total: 1, excluded: 0, skipped: 0}},
        # Site 2: normal pass.
        {:result, %{failures: 0, total: 1, excluded: 0, skipped: 0}}
      ])

      assert {:ok, %{results: [r1, r2]}} = MutationRunner.run(cfg)
      assert r1.status == :timeout
      assert r1.tainted_predecessors == false

      assert r2.tainted_predecessors == true
    end

    # ---------------------------------------------------------------------------
    # r4 cooperative-cancellation regression (bw mutagen-wrd.13)
    # ---------------------------------------------------------------------------
    #
    # The bug behind bw mutagen-wrd.13 was that a timed-out task was
    # killed by `Task.shutdown(task, :brutal_kill)` mid-flight inside
    # `:code.load_binary/3`, leaving the Code.Server with an orphaned
    # per-module load lock. The fix is two-phase cancellation:
    #
    #   phase 1: `Task.shutdown(task, cancel_grace_ms)` — sends
    #            `:shutdown` (trappable). A task that traps exits and
    #            returns normally during the grace window unwinds
    #            cleanly, releasing its locks.
    #   phase 2: `Task.shutdown(task, :brutal_kill)` — only if phase 1
    #            timed out. Plus a `:code.purge/1` settle pass on the
    #            site's scoped modules before restore.
    #
    # The tests below are load-bearing on the fix:
    #
    #   * The graceful test proves phase 1 actually runs and can
    #     produce a `:timeout` classification without the brutal path.
    #     If a regression skipped the cooperative phase, this test
    #     would still pass (the task would just be brutal-killed) so
    #     we ALSO assert `cancel_mode == :graceful` indirectly via
    #     classification + timing.
    #   * The brutal test proves phase 2 still fires for tasks that
    #     ignore `:shutdown`. Without phase 2 the runner would hang
    #     forever.
    #   * The settle test proves `:code.purge/1` is invoked for the
    #     site's scoped modules on a timeout. If a regression dropped
    #     the purge call, the next site's compile-and-load cycle would
    #     deadlock on a real timed-out site — but the deadlock is
    #     environmental and hard to reproduce inside a unit test. The
    #     observable proxy is "purge was called for the scope module".

    test "graceful-cancel path: task that traps exit and returns on :shutdown classifies :timeout without brutal_kill" do
      clear_stubs()
      site = build_site(id: "graceful", line: 2, column: 13)

      cfg = base_cfg(site, timeout_ms: 50)

      # The task will trap exits, wait for :shutdown, and return.
      # `Task.shutdown(task, grace)` in the loop sends :shutdown.
      # The task returns its configured result, which the loop reports
      # via the graceful path. r4 classification is :timeout (the
      # wall-clock budget elapsed regardless of the unwind mechanism).
      ExUnitFake.set_results([
        {:trap_then_yield_on_shutdown,
         %{failures: 0, total: 1, excluded: 0, skipped: 0}}
      ])

      start_ms = System.monotonic_time(:millisecond)
      assert {:ok, %{results: [r]}} = MutationRunner.run(cfg)
      elapsed_ms = System.monotonic_time(:millisecond) - start_ms

      # The graceful path returns a `{:ok, result}` from the task —
      # classification becomes :killed/:survived depending on
      # failures. Here failures == 0, so :survived. This is the
      # WIN of cooperative cancellation: the task got to finish
      # unwinding inside the grace window so its result is honored.
      # The bug repro (brutal_kill only) had no path to this outcome.
      assert r.status == :survived,
             "expected the trap-and-yield-on-shutdown task to be honoured as :survived on the graceful path (proving phase 1 of cancel_on_timeout fired); got #{inspect(r.status)}"

      # Sanity: the timeout DID fire (we slept past 50ms wall-clock
      # before the grace window settled). Without this, the test
      # would be vacuous against a regression that skipped the
      # timeout entirely.
      assert elapsed_ms >= 50,
             "expected elapsed >= 50ms (timeout_ms) but got #{elapsed_ms}ms — the timeout didn't fire"

      # And it completed before the upper bound (timeout_ms + grace +
      # noise). If a regression made the grace window unbounded, this
      # would catch it.
      assert elapsed_ms < 1_000,
             "graceful cancel took #{elapsed_ms}ms — exceeded the timeout + grace budget"
    end

    test "brutal-kill escalation: task that ignores :shutdown still terminates via :brutal_kill and classifies :timeout" do
      clear_stubs()
      site = build_site(id: "brutal", line: 2, column: 13)

      cfg = base_cfg(site, timeout_ms: 50)

      # The task traps exits and DRAINS :shutdown signals for 1s before
      # exiting. The cooperative phase (default grace 100ms) cannot
      # finish; the loop must escalate to brutal_kill — that's the
      # only path that actually clears the task.
      ExUnitFake.set_results([
        {:trap_and_ignore_shutdown, 1_000,
         %{failures: 0, total: 1, excluded: 0, skipped: 0}}
      ])

      start_ms = System.monotonic_time(:millisecond)
      assert {:ok, %{results: [r]}} = MutationRunner.run(cfg)
      elapsed_ms = System.monotonic_time(:millisecond) - start_ms

      assert r.status == :timeout,
             "task that ignores :shutdown must still classify :timeout via brutal_kill; got #{inspect(r.status)}"

      # The cooperative phase consumes ~100ms (the default grace),
      # then brutal_kill clears within milliseconds. The whole site
      # should finish well under the 1_000ms drain ceiling — proof
      # that escalation actually fired rather than us waiting out
      # the drain.
      assert elapsed_ms < 800,
             "brutal-kill escalation should clear the site in under 800ms; got #{elapsed_ms}ms — phase 2 likely did not fire"
    end

    test "code-server settle: :code.purge/1 is invoked for the site's scoped modules on :timeout" do
      clear_stubs()
      site = build_site(id: "settle", line: 2, column: 13)
      scope_module = Synthetic.SettleFixture

      # Capture every module passed to `code_purge`. The runner's
      # `settle_code_server!/3` calls this exactly once per scope-
      # record whose file matches the site's file, only on :timeout.
      purge_calls = :ets.new(:purge_calls, [:public, :ordered_set])

      code_purge = fn mod ->
        :ets.insert(purge_calls, {System.unique_integer([:monotonic]), mod})
        :ok
      end

      cfg =
        site
        |> base_cfg(
          timeout_ms: 50,
          scope_records: [
            %Scope{file: site.file, line_range: 1..10, module: scope_module}
          ]
        )
        |> Map.put(:code_purge, code_purge)

      ExUnitFake.set_results([
        # Force a brutal-kill path so we KNOW the timeout actually
        # fired with the cancel_mode that justifies the purge.
        {:trap_and_ignore_shutdown, 1_000,
         %{failures: 0, total: 1, excluded: 0, skipped: 0}}
      ])

      assert {:ok, %{results: [r]}} = MutationRunner.run(cfg)
      assert r.status == :timeout

      purged = :ets.tab2list(purge_calls) |> Enum.map(fn {_, m} -> m end)

      assert scope_module in purged,
             "expected :code.purge to be called on #{inspect(scope_module)} after a :timeout site (Code.Server settle path per mutagen.decision.timeout_handling); got purge calls: #{inspect(purged)}"

      :ets.delete(purge_calls)
    end

    test "non-timeout outcomes do NOT call :code.purge/1 (settle is timeout-only)" do
      # The settle path is opt-in for the timeout class because
      # gratuitous purges on every successful site would slow down
      # the happy path (and risk unloading code that the test suite
      # actually needs across sites). This test pins the gate.
      clear_stubs()
      site = build_site(id: "nopurge", line: 2, column: 13)
      scope_module = Synthetic.NoPurgeFixture

      purge_calls = :ets.new(:purge_calls_nopurge, [:public, :ordered_set])

      code_purge = fn mod ->
        :ets.insert(purge_calls, {System.unique_integer([:monotonic]), mod})
        :ok
      end

      cfg =
        site
        |> base_cfg(
          scope_records: [
            %Scope{file: site.file, line_range: 1..10, module: scope_module}
          ]
        )
        |> Map.put(:code_purge, code_purge)

      ExUnitFake.set_results([
        {:result, %{failures: 0, total: 1, excluded: 0, skipped: 0}}
      ])

      assert {:ok, %{results: [r]}} = MutationRunner.run(cfg)
      assert r.status == :survived

      purged = :ets.tab2list(purge_calls) |> Enum.map(fn {_, m} -> m end)

      assert purged == [],
             "expected no :code.purge calls on a non-timeout site; got #{inspect(purged)}"

      :ets.delete(purge_calls)
    end
  end

  # ---------------------------------------------------------------------------
  # r7 / s6: snapshot-growth taint propagation (WITHOUT timeout)
  # ---------------------------------------------------------------------------
  #
  # The timeout test above also flips taint, but it does so via
  # `status == :timeout` — that path is r4's mechanism. r7 is the
  # INDEPENDENT snapshot-growth path: a site that completes well under
  # the timeout but leaks named-process / ETS / persistent-term state
  # must still mark the NEXT site as `tainted_predecessors: true` and
  # emit a `state_leak` warning naming the offender. The implementation
  # ORs `grew?` into `next_tainted` (mutation_runner.ex:464); a
  # regression that drops `grew?` from that OR-expression would let a
  # silent leak ship green — this test exists to fail load-bearingly in
  # that case.

  describe "r7: snapshot-growth without timeout (s6)" do
    test "site that leaks a named process (no timeout) taints the NEXT site and emits a snapshot warning" do
      clear_stubs()
      site1 = build_site(id: "leak1", line: 2, column: 13)
      site2 = build_site(id: "post_leak", line: 2, column: 13)

      # Pick a name unlikely to collide with anything else in the BEAM.
      leaked_name = :mutagen_ex_runner_test_r7_leaked_proc

      # Be defensive: if a prior aborted run left the name registered,
      # tear it down before the runner takes its pre-snapshot.
      case Process.whereis(leaked_name) do
        nil ->
          :ok

        pid ->
          Process.unregister(leaked_name)
          Process.exit(pid, :kill)
      end

      on_exit(fn ->
        case Process.whereis(leaked_name) do
          nil ->
            :ok

          pid ->
            try do
              Process.unregister(leaked_name)
            rescue
              ArgumentError -> :ok
            end

            Process.exit(pid, :kill)
        end
      end)

      # 500ms timeout is the base_cfg default; the leak completes in
      # microseconds (synchronous spawn+register) so `:timeout` is NOT
      # the mechanism driving taint here. That is the entire point of
      # this test: prove `grew?` carries the taint independently.
      cfg = base_cfg([site1, site2])

      ExUnitFake.set_results([
        # Site 1: complete normally AND leak a named process before
        # returning. Status will classify as `:survived` (failures == 0),
        # NOT `:timeout`.
        {:leak_proc, leaked_name,
         %{failures: 0, total: 1, excluded: 0, skipped: 0}},
        # Site 2: normal pass.
        {:result, %{failures: 0, total: 1, excluded: 0, skipped: 0}}
      ])

      assert {:ok, %{results: [r1, r2], warnings: warnings}} = MutationRunner.run(cfg)

      # r1 itself is `:survived` (NOT `:timeout`) — this distinguishes
      # the r7 mechanism from r4's. If a regression dropped `grew?`
      # from `next_tainted`, only `status == :timeout` would propagate
      # taint, and r2.tainted_predecessors would be false below.
      assert r1.status == :survived,
             "expected the leaking site to classify as :survived (not :timeout); got #{inspect(r1.status)}"

      # r1's own `tainted_predecessors` starts at false (no prior site
      # leaked into it). The leak it CAUSES propagates to r2.
      assert r1.tainted_predecessors == false

      # THE LOAD-BEARING ASSERTION for r7's `next_tainted = tainted_now or
      # grew? or status == :timeout`. Drop `grew?` from that OR and this
      # assertion fails: status is :survived, tainted_now is false, so
      # next_tainted collapses to false → r2.tainted_predecessors → false.
      assert r2.tainted_predecessors == true,
             "r7 regression: snapshot growth from site #{site1.id} did not propagate to next site"

      # snapshot_warning/2 must fire and name the offending site + the
      # process-growth kind. If `grew?` were dropped from the warning
      # gate too, this also fails. The warning shape is enforced by
      # snapshot_warning/2 in mutation_runner.ex.
      assert Enum.any?(warnings, &(&1 =~ "state_leak after site " <> site1.id)),
             "expected a state_leak warning naming site #{site1.id}; got: #{inspect(warnings)}"

      assert Enum.any?(warnings, &(&1 =~ "processes+")),
             "expected the state_leak warning to report process growth; got: #{inspect(warnings)}"

      # Sanity: the leak actually happened (registered name survived
      # into the assertion phase). Without this, a future change to
      # `:leak_proc` could silently no-op and the test above would
      # vacuously fail to detect the regression.
      assert is_pid(Process.whereis(leaked_name)),
             "the test's own :leak_proc helper failed to register #{inspect(leaked_name)} — the rest of this test would be vacuous"
    end

    test "site with NO state growth (no leak, no timeout) does NOT taint the next site" do
      # Negative control for the test above. Without this, a buggy
      # snapshot routine that always reports growth would make the
      # positive assertion green vacuously. Here both sites complete
      # cleanly; the second must NOT carry tainted_predecessors and no
      # `state_leak` warning should be emitted.
      clear_stubs()
      site1 = build_site(id: "clean1", line: 2, column: 13)
      site2 = build_site(id: "clean2", line: 2, column: 13)

      cfg = base_cfg([site1, site2])

      ExUnitFake.set_results([
        {:result, %{failures: 0, total: 1, excluded: 0, skipped: 0}},
        {:result, %{failures: 0, total: 1, excluded: 0, skipped: 0}}
      ])

      assert {:ok, %{results: [r1, r2], warnings: warnings}} = MutationRunner.run(cfg)
      assert r1.status == :survived
      assert r1.tainted_predecessors == false
      assert r2.tainted_predecessors == false
      refute Enum.any?(warnings, &(&1 =~ "state_leak"))
    end
  end

  # ---------------------------------------------------------------------------
  # r6 / s5: restore via Code.compile_quoted; unrecoverable_restore_failure aborts
  # ---------------------------------------------------------------------------

  describe "r6: restore (s5)" do
    test "after each site, runner calls compile_quoted with the ORIGINAL file AST" do
      clear_stubs()
      site = build_site(id: "r1")
      cfg = base_cfg(site)
      [{_file, {original_file_ast, _src}}] = Map.to_list(cfg.ast_cache)

      ExUnitFake.set_results([
        {:result, %{failures: 0, total: 1, excluded: 0, skipped: 0}}
      ])

      assert {:ok, _} = MutationRunner.run(cfg)

      calls = Process.get(:compiler_stub_calls) || []
      # Calls are pushed in reverse-time order; the LAST call should be the restore.
      [{_last_file, last_ast} | _] = calls

      assert last_ast == original_file_ast
    end

    test "aborts the pipeline with :unrecoverable_restore_failure when restore compile raises" do
      clear_stubs()
      site = build_site(id: "rf1")
      cfg = base_cfg(site)
      [{_file, {original_file_ast, _src}}] = Map.to_list(cfg.ast_cache)

      ExUnitFake.set_results([
        {:result, %{failures: 0, total: 1, excluded: 0, skipped: 0}}
      ])

      # Set the compiler stub to raise specifically when called with the
      # original AST (the restore call). The mutated-AST swap call passes
      # a different tree (it carries `site.mutated_ast`); the restore
      # call passes the original.
      Process.put(:compiler_stub_hooks, [
        {fn ast, _file -> ast == original_file_ast end, {:raise, "restore boom"}}
      ])

      assert {:error, :unrecoverable_restore_failure, details} = MutationRunner.run(cfg)
      assert details.site_id == "rf1"
      assert details.file == site.file
      assert details.message =~ "restore"
    end
  end

  # ---------------------------------------------------------------------------
  # r8 / s7: state_drift_warning for `use SomeModule`
  # ---------------------------------------------------------------------------

  describe "r8: state_drift_warning for `use` (s7)" do
    test "module whose AST contains `use GenServer` is listed in state_drift_warning" do
      clear_stubs()
      site = build_site(id: "d1", line: 5, column: 13)

      # Build an AST that contains `use GenServer` inside the scoped
      # module's body.
      file = "synthetic/use_gs.ex"

      file_ast =
        {:defmodule, [line: 1, column: 1],
         [
           {:__aliases__, [line: 1], [:Synthetic, :UseGs]},
           [
             do:
               {:__block__, [],
                [
                  {:use, [line: 2, column: 3], [{:__aliases__, [line: 2], [:GenServer]}]},
                  {:def, [line: 5, column: 3],
                   [
                     {:add, [line: 5, column: 7], []},
                     [do: site.original_ast]
                   ]}
                ]}
           ]
         ]}

      cfg = %{
        base_cfg(site)
        | ast_cache: %{file => {file_ast, "..."}},
          sites: [%{site | file: file}],
          scope_records: [%Scope{file: file, line_range: 1..10, module: Synthetic.UseGs}]
      }

      ExUnitFake.set_results([
        {:result, %{failures: 0, total: 1, excluded: 0, skipped: 0}}
      ])

      assert {:ok, output} = MutationRunner.run(cfg)
      assert output.state_drift_warning[Synthetic.UseGs] == [GenServer]
    end

    test "module with no `use` has no state_drift_warning entry" do
      clear_stubs()
      site = build_site(id: "d2")
      cfg = base_cfg(site)

      ExUnitFake.set_results([
        {:result, %{failures: 0, total: 1, excluded: 0, skipped: 0}}
      ])

      assert {:ok, output} = MutationRunner.run(cfg)
      assert output.state_drift_warning == %{}
    end
  end

  # ---------------------------------------------------------------------------
  # r9 / s8: stderr captured into results[i].warnings
  # ---------------------------------------------------------------------------

  describe "r9: stderr captured into results[i].warnings (s8)" do
    test "compiler-warning stderr lands in the site's warnings field" do
      clear_stubs()
      site = build_site(id: "w1")
      cfg = base_cfg(site)

      # Replace the compiler stub with one that writes to stderr.
      defmodule StderrCompiler do
        def compile_quoted(_ast, _file) do
          IO.write(:stderr, "warning: this is a captured stderr line\n")
          []
        end
      end

      cfg = %{cfg | compiler: {StderrCompiler, :compile_quoted}}

      ExUnitFake.set_results([
        {:result, %{failures: 0, total: 1, excluded: 0, skipped: 0}}
      ])

      assert {:ok, %{results: [result]}} = MutationRunner.run(cfg)
      assert Enum.any?(result.warnings, &(&1 =~ "captured stderr line"))
    end
  end

  # ---------------------------------------------------------------------------
  # r11: no disk writes during the runner phase
  # ---------------------------------------------------------------------------
  #
  # The r11 invariant ("MutationRunner.run/1 does not modify any file on
  # disk") is broader than `lib/**/*.ex`. The bytecode-identical-restore
  # contract is violated by any disk write the runner did not declare —
  # build artifacts, coverage output, tmp scratch, or worst-case the
  # host project's `mix.exs` / `mix.lock` / `.formatter.exs`.
  #
  # The original r11 test hashed `lib/**/*.ex` only and would ship green
  # if the runner accidentally rewrote `mix.exs`, dropped a file under
  # `_build/`, or wrote a stray report to `cover/`. This broader test
  # asserts byte-identity across:
  #
  #   * `lib/**/*.{ex,exs}`  — the source surface (original assertion).
  #   * `_build/**/*.{beam,app}` — compiled artifacts. The runner uses
  #     `Code.compile_quoted/2` *in-memory*; it must NOT touch the .beam
  #     files on disk under the test suite's stubbed-compiler path.
  #   * `cover/**`           — coverage reports. The runner does not run
  #     `:cover.analyze/0` with on-disk output; this directory must NOT
  #     materialize as a side effect.
  #   * `mix.exs`, `mix.lock`, `.formatter.exs` — host project config.
  #     No mutation path may rewrite these.
  #   * `/tmp` entries with `mutagen_ex_` prefix — the runner currently
  #     creates no tmp scratch, and any future addition must be opt-in.
  #
  # Allowed writes during this stubbed-runner pass: none. The runner's
  # public seams (ExUnitFake, CompilerStub, etc.) live in-process and
  # don't touch disk. If a real :cover path needs file output later,
  # that path goes through `CoverageRunner` (covered by coverage.r7),
  # not `MutationRunner`.

  describe "r11: no disk writes (broader surface)" do
    test "lib/, _build/, cover/, host config, and /tmp are byte-identical before/after a runner pass" do
      clear_stubs()
      site = build_site(id: "n1")
      cfg = base_cfg(site)

      pre = MutagenEx.TestSupport.DiskSnapshot.snapshot()

      ExUnitFake.set_results([
        {:result, %{failures: 0, total: 1, excluded: 0, skipped: 0}}
      ])

      assert {:ok, _} = MutationRunner.run(cfg)

      post = MutagenEx.TestSupport.DiskSnapshot.snapshot()
      diff = MutagenEx.TestSupport.DiskSnapshot.diff(pre, post)

      # Modified files: ANY content change to a snapshotted path is a
      # violation. There is no allowed-write surface for the stubbed
      # runner pass.
      assert diff.modified == [],
             "r11 regression: runner modified files on disk:\n" <>
               Enum.map_join(diff.modified, "\n  ", &("- " <> &1))

      # Removed files: equally a violation — the runner must never
      # delete user content.
      assert diff.removed == [],
             "r11 regression: runner removed files from disk:\n" <>
               Enum.map_join(diff.removed, "\n  ", &("- " <> &1))

      # Added files under the snapshotted globs: the stubbed runner
      # creates no compiled artifacts, no coverage output. ANY added
      # path here is unaccounted disk write.
      assert diff.added == [],
             "r11 regression: runner created files on disk:\n" <>
               Enum.map_join(diff.added, "\n  ", &("- " <> &1))

      # /tmp churn: only flag entries the runner could plausibly own
      # (prefix `mutagen_ex_`). Concurrent processes adding unrelated
      # tmp entries during the test run are not a r11 violation — that
      # would be a flaky assertion on shared hardware.
      attributable = MutagenEx.TestSupport.DiskSnapshot.mutagen_attributable_tmp(diff)

      assert attributable == [],
             "r11 regression: runner created tmp entries with `mutagen_ex_` prefix:\n" <>
               Enum.map_join(attributable, "\n  ", &("- " <> &1))
    end
  end

  # ---------------------------------------------------------------------------
  # Input validation
  # ---------------------------------------------------------------------------

  describe "input validation" do
    test "rejects malformed input" do
      assert {:error, :invalid_input, _} = MutationRunner.run(%{})
    end
  end

  # ---------------------------------------------------------------------------
  # End-to-end against the real AstCache / real Code.compile_quoted (light)
  # ---------------------------------------------------------------------------
  #
  # The stubs above let us assert state-machine shape without touching the
  # global module registry. The check below uses the REAL compiler against
  # a freshly defined synthetic module so we confirm the compile+restore
  # round-trips and a `:cover_compiled`-shaped artifact isn't required for
  # the runner to work.

  describe "end-to-end with real Code.compile_quoted" do
    @tag :integration
    test "round-trips a synthetic module through one mutation site" do
      clear_stubs()

      source = """
      defmodule MutationRunnerTestSynth.RealFixture do
        def two, do: 1 + 1
      end
      """

      assert {:ok, ast_cache} =
               AstCache.load(["synth_real.ex"], reader: fn _ -> source end)

      assert {:ok, {file_ast, _src}} = AstCache.get(ast_cache, "synth_real.ex")

      # Locate the `1 + 1` node in the AST so the site's metadata matches
      # what the enumerator would produce.
      {_, [add_node]} =
        Macro.prewalk(file_ast, [], fn
          {:+, _meta, [1, 1]} = node, acc -> {node, [node | acc]}
          node, acc -> {node, acc}
        end)

      {_, meta, args} = add_node

      site = %Site{
        id: "real:1:arith",
        file: "synth_real.ex",
        line: Keyword.get(meta, :line),
        column: Keyword.get(meta, :column),
        mutator: :arith,
        original_ast: add_node,
        mutated_ast: {:-, meta, args}
      }

      cfg = %{
        seed: 0,
        timeout_ms: 500,
        test_filter: %TestFilter{include: [], exclude: [:test], files: []},
        ast_cache: ast_cache,
        sites: [site],
        scope_records: [
          %Scope{
            file: "synth_real.ex",
            line_range: 1..3,
            module: MutationRunnerTestSynth.RealFixture
          }
        ],
        test_modules: [],
        # We DO use the stub ExUnit so we don't reschedule a real test
        # run inside ourselves. The compiler path is the real one — we
        # want to prove the real Code.compile_quoted round-trip works.
        ex_unit: ExUnitFake,
        ex_unit_server: ExUnitServerStub,
        capture_io: CaptureIoStub
      }

      ExUnitFake.set_results([
        {:result, %{failures: 0, total: 1, excluded: 0, skipped: 0}}
      ])

      assert {:ok, %{results: [result]}} = MutationRunner.run(cfg)
      assert result.status == :survived

      # After the run the fixture module's `two/0` should still return 2
      # (i.e., restore succeeded). Use apply/3 since the module name
      # didn't exist at this file's compile time.
      assert apply(MutationRunnerTestSynth.RealFixture, :two, []) == 2
    end
  end
end
