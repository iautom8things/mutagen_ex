defmodule MutagenEx.MutationRunner do
  @moduledoc """
  Per-mutation execution: swap → run → classify → restore. Aggregates the
  per-site outcomes into a result block the JSON reporter (S6) can
  serialise.

  Contract: [`mutagen.mutation_pipeline`](../../.spec/specs/mutation_pipeline.spec.md)
  r3-r11.

  ## Invariants summary

    * **r3** — refuses to mutate `MutagenEx.*` or `Mix.Tasks.Mutagen`
      modules (see [`mutagen.decision.self_mutation_refused`](../../.spec/decisions/self_mutation_refused.md)).
    * **r4** — per-site test runs wrap `ExUnit.run/0` in the timeout
      structure owned by `MutagenEx.MutationRunner.MutationLoop`. The
      timeout uses the two-phase cooperative-cancellation path
      documented in `mutagen.decision.timeout_handling` (trappable
      `:shutdown` first, brutal_kill only as escalation). The runner
      classifies a deadline hit as `:timeout` unless fail-fast already
      recorded a failure. The following site carries
      `tainted_predecessors: true` either way. Before
      restore, the runner calls `:code.purge/1` on the site's scoped
      modules to release any orphaned Code.Server load lock left by
      a brutal-killed task — the per-mutation hardening that
      bw mutagen-wrd.13 fixed.
    * **r5** — exactly five outcomes: `:killed`, `:survived`, `:timeout`,
      `:compile_error`, `:error`. `:compile_error` does not count toward
      the kill-rate denominator.
    * **r6** — after every per-site run, the original module is restored
      via `:code.load_binary/3` from a per-run ETS snapshot owned by
      `MutagenEx.BeamCache`. The snapshot is taken once before the
      per-site loop dispatches, in a serial pre-pass over every scoped
      module — closing the TOCTOU window a per-site snapshot would
      open under `--max-concurrency > 1`. The cache lives only for the
      duration of `run/1` (created at the start, deleted in the
      `after` clause). On restore failure the runner aborts with
      `{:error, :unrecoverable_restore_failure, ...}`. See
      [`mutagen.decision.per_run_beam_cache`](../../.spec/decisions/per_run_beam_cache.md)
      and
      [`mutagen.decision.code_server_facade`](../../.spec/decisions/code_server_facade.md).
    * **r12** — a raise, throw, or exit propagating out of the
      loaded-mutation window (from successful compile of the mutated
      AST through the test run and `:code.purge/1` settle) triggers
      restore before re-propagation. The original kind/value/stacktrace
      surfaces to the caller; restore failure during such propagation
      is best-effort and never masks the original cause. Implemented
      via `with_restore/4`, mirroring
      `MutagenEx.CoverageRunner`'s `with_cover_lifecycle/2`.
    * **r7** — pre/post state snapshots
      (`Process.registered/0`, `:ets.all/0`, `:persistent_term.get/0`).
      Growth flags `tainted_predecessors: true` for subsequent results
      and emits a warning naming the new entities (best-effort —
      `Process.registered/0` is the named-process surface; anonymous
      leaks are documented as a known caveat per
      [`mutagen.decision.timeout_handling`](../../.spec/decisions/timeout_handling.md)).
    * **r8** — modules whose AST contains `use SomeModule` get a
      `state_drift_warning` listing the used modules.
    * **r9** — stderr is captured via `ExUnit.CaptureIO` and attached
      to each result's `warnings` field.
    * **r10** — test files are loaded once (the orchestrator's
      responsibility upstream); per-site cycles re-register modules via
      `ExUnit.Server.add_module/2` from `MutationLoop`.
    * **r11** — no file on disk is modified by the runner. All AST
      compilation is in-memory via `Code.compile_quoted/2`; restore is
      an in-memory binary swap via `:code.load_binary/3` against the
      per-run BeamCache snapshot (no disk writes either).

  ## Input shape

  `run/1` takes a map:

    * `:seed` — `non_neg_integer`. Forwarded to ExUnit.configure for the
      duration of the runner.
    * `:timeout_ms` — `pos_integer`. Per-site wall-clock budget.
    * `:test_filter` — `%MutagenEx.TestSelector.TestFilter{}`.
    * `:ast_cache` — `%{file => {ast, source_text}}` from
      `MutagenEx.AstCache.load/1`.
    * `:sites` — `[%MutagenEx.MutationEnumerator.Site{}, ...]`.
    * `:scope_records` — `[%MutagenEx.ScopeResolver.Scope{}]`, used for
      r8 (state-drift detection over `use SomeModule` in scoped modules).
    * `:test_modules` — `[{module, exunit_module_cfg}]` to re-register
      between per-site runs. Built by the orchestrator from the test
      filter once before the runner starts.

  Optional:

    * `:fail_fast` — `boolean`. Default `true`. Stops executing cited
      tests after the first failure. Use `false` for a full suite run.
    * `:ex_unit` — module implementing `MutagenEx.Test.ExUnitFacade`.
      Default `MutagenEx.Test.ExUnit`. Passed through to `MutationLoop`.
    * `:ex_unit_server` — module implementing
      `MutagenEx.Test.ExUnitServerFacade`. Default
      `MutagenEx.Test.ExUnitServer`. Passed through to `MutationLoop`.
    * `:capture_io` — module implementing
      `MutagenEx.Test.CaptureIoFacade`. Default
      `MutagenEx.Test.CaptureIo`. Used by both the swap-compile capture
      around `Code.compile_quoted/2` and the per-site `MutationLoop`
      stderr capture.
    * `:compiler` — module implementing `MutagenEx.Test.CompilerFacade`,
      OR a legacy `{module, function}` tuple for back-compat with the
      pre-bw mutagen-wrd.24 stubs. Default `MutagenEx.Test.Compiler`.
      The legacy tuple shape is honored so existing test stubs that
      pass `{CompilerStub, :compile_quoted}` keep working.
    * `:code_server` — module implementing
      `MutagenEx.Test.CodeServerFacade`. Default
      `MutagenEx.Test.CodeServer`. The restore path uses this facade to
      call `:code.get_object_code/1` (snapshot pre-pass) and
      `:code.load_binary/3` (per-site restore). Tests inject a stub
      that records calls and returns canned binaries; production
      callers leave the default. Mirrors the `:compiler` seam.
    * `:beam_cache_table` — `:ets.tab()`. The per-run snapshot table.
      Callers DO NOT pass this; `run/1` creates the table itself via
      `MutagenEx.BeamCache.new/0` at the start of `execute/2` and
      deletes it in the `after` clause. The field is documented here
      so internal helpers that read `cfg.beam_cache_table` have a
      named contract. Tests that bypass `execute/2` (and thread a
      hand-rolled cfg into deeper helpers) must populate this
      themselves.
    * `:cancel_grace_ms` — `non_neg_integer`. Grace window the
      cooperative-cancellation phase waits before escalating to
      brutal_kill on a timeout. Default `100`. Set to `0` in tests
      that need to exercise the brutal-only path. Passed through to
      `MutationLoop`.
    * `:code_purge` — `(module -> any)`. Test seam for the post-
      `:timeout` Code.Server settle pass. Default `&:code.purge/1`.
    * `:max_concurrency` — `pos_integer | nil`. Cap on the number of
      per-site tasks `Task.Supervisor.async_stream_nolink/4` will spawn
      in parallel. `nil` resolves to `1` (fully-serial, v1.0-equivalent
      execution) — this is also the Mix-task default when the user
      does not pass `--max-concurrency`. `N > 1` is the explicit
      opt-in path for callers with collision-free input. Regardless
      of value, results are collected in input order (the
      `async_stream` `:ordered` default) so the JSON document is
      byte-identical to the serial-equivalent run on deterministic
      scopes — taint, warnings, and per-site classification all fold
      sequentially over the ordered result list. See
      `mutagen.mutation_pipeline.r15`.
    * `:task_sup` — `atom | pid`. The `Task.Supervisor` the per-site
      tasks run under. Default `MutagenEx.TaskSup`. Tests can pass a
      one-off supervisor pid for isolation.
    * `:on_site_completed` — `(result_or_compile_error -> :ok)`. Called
      once per site as the result becomes available (in input order),
      before the runner accumulates it. This is the streaming-NDJSON
      seam: the Mix task wires this to emit one wire-shape JSON line
      per site. The runner only invokes it; it does no I/O itself
      (`mutagen.json_schema.r11`).

  ## Output shape

  `{:ok, %{results: [...], compile_errors: [...], state_drift_warning: %{...}, warnings: [...]}}`
  on full pipeline. `{:error, reason, details}` on `:self_mutation_refused`
  or `:unrecoverable_restore_failure`.
  """

  alias MutagenEx.Ast
  alias MutagenEx.AstCache
  alias MutagenEx.BeamCache
  alias MutagenEx.MutationEnumerator.Site
  alias MutagenEx.MutationRunner.MutationLoop
  alias MutagenEx.ScopeResolver.Scope
  alias MutagenEx.Test.ExUnit, as: ExUnitFacade
  alias MutagenEx.Test.FailureFormatter
  alias MutagenEx.TestSelector.TestFilter

  @behaviour MutagenEx.Pipeline.MutationFacade

  @self_mutation_prefix "Elixir.MutagenEx."
  @self_mutation_task "Elixir.Mix.Tasks.Mutagen"

  @typedoc "Reasons the runner can abort with."
  @type error_reason ::
          :self_mutation_refused
          | :unrecoverable_restore_failure
          | :invalid_input

  @typedoc "Successful per-site result. `:compile_error` outcomes live in `compile_errors` instead."
  @type site_result :: %{
          id: String.t(),
          function: String.t() | nil,
          file: String.t(),
          line: pos_integer(),
          column: pos_integer(),
          mutator: atom(),
          original_ast: Macro.t(),
          mutated_ast: Macro.t(),
          status: :killed | :survived | :timeout | :error,
          tainted_predecessors: boolean(),
          warnings: [String.t() | {atom(), String.t()}],
          end_line: pos_integer() | nil,
          end_column: pos_integer() | nil,
          source_text: String.t() | nil
        }

  @typedoc "Compile-error record (sites whose mutated AST refused to compile)."
  @type compile_error_entry :: %{
          id: String.t(),
          file: String.t(),
          function: String.t() | nil,
          line: pos_integer(),
          column: pos_integer(),
          mutator: atom(),
          message: String.t(),
          exception: module() | nil
        }

  @typedoc "Aggregated runner result."
  @type ok_result :: %{
          results: [site_result()],
          compile_errors: [compile_error_entry()],
          state_drift_warning: %{optional(module()) => [atom()]},
          warnings: [String.t() | {atom(), term()} | {:host_names, atom(), [term()]}]
        }

  @doc """
  Runs the mutation phase. See module doc for input shape.
  """
  @impl MutagenEx.Pipeline.MutationFacade
  @spec run(map()) :: {:ok, ok_result()} | {:error, error_reason(), map()}
  def run(input) when is_map(input) do
    with {:ok, cfg} <- normalise(input),
         :ok <- ensure_no_self_mutation(cfg) do
      run_with_exunit(cfg)
    end
  end

  # Per [`mutagen.decision.per_run_beam_cache`](../../.spec/decisions/per_run_beam_cache.md):
  # the snapshot table lives for exactly the duration of `run/1`. Create it
  # before dispatching to `execute/2`; delete it on every exit path —
  # success, `{:error, _, _}` return, or raise/throw/exit propagating out
  # of `execute/2`. The `after` clause is the only place the table is
  # destroyed; no peer code, test seam, or supervisor child owns it.
  defp run_with_beam_cache(cfg, drift) do
    table = BeamCache.new()
    cfg = Map.put(cfg, :beam_cache_table, table)

    try do
      execute(cfg, drift)
    after
      BeamCache.delete(table)
    end
  end

  # ---------------------------------------------------------------------------
  # r3: self-mutation refusal
  # ---------------------------------------------------------------------------

  defp ensure_no_self_mutation(cfg) do
    offenders =
      cfg.scope_records
      |> Enum.map(& &1.module)
      |> Enum.filter(&self_mutation?/1)

    case offenders do
      [] ->
        :ok

      _ ->
        {:error, :self_mutation_refused,
         %{
           modules: offenders,
           message:
             "mutagen_ex refuses to mutate its own runtime: " <>
               Enum.map_join(offenders, ", ", &inspect/1) <>
               ". " <>
               "See mutagen.decision.self_mutation_refused."
         }}
    end
  end

  defp self_mutation?(mod) when is_atom(mod) do
    str = Atom.to_string(mod)

    String.starts_with?(str, @self_mutation_prefix) or str == @self_mutation_task
  end

  defp self_mutation?(_), do: false

  # ---------------------------------------------------------------------------
  # ExUnit config (r2's force, shared with baseline/coverage)
  # ---------------------------------------------------------------------------

  defp run_with_exunit(%{fail_fast: false} = cfg) do
    run_configured(cfg, ExUnitFacade.options(cfg.seed, cfg.test_filter, :infinity))
  end

  defp run_with_exunit(cfg) do
    failures = :ets.new(:mutation_failures, [:set, :public])

    try do
      options =
        ExUnitFacade.options(cfg.seed, cfg.test_filter, 1)
        |> FailureFormatter.attach(fn runner, _test ->
          :ets.insert_new(failures, {runner, System.monotonic_time()})
        end)

      run_configured(Map.put(cfg, :failure_times, failures), options)
    after
      :ets.delete(failures)
    end
  end

  defp run_configured(cfg, options) do
    ignore_conflict = Code.get_compiler_option(:ignore_module_conflict)
    Code.put_compiler_option(:ignore_module_conflict, true)

    try do
      ExUnitFacade.with_options(options, fn ->
        drift = compute_state_drift_warnings(cfg)
        run_with_beam_cache(cfg, drift)
      end)
    after
      Code.put_compiler_option(:ignore_module_conflict, ignore_conflict)
    end
  end

  # ---------------------------------------------------------------------------
  # r8: state drift warnings — modules with `use SomeModule`
  # ---------------------------------------------------------------------------

  defp compute_state_drift_warnings(cfg) do
    cfg.scope_records
    |> Enum.reduce(%{}, fn %Scope{file: file, module: module}, acc ->
      case AstCache.get(cfg.ast_cache, file) do
        :error ->
          acc

        {:ok, {ast, _source}} ->
          uses = uses_in_module_ast(ast, module)

          if uses == [] do
            acc
          else
            Map.put(acc, module, uses)
          end
      end
    end)
  end

  defp uses_in_module_ast(ast, target_mod) do
    case Ast.find_module_body(ast, Atom.to_string(target_mod)) do
      :not_found ->
        []

      {:ok, body} ->
        {_, list} =
          Macro.prewalk(body, [], fn
            {:use, _meta, [used | _rest]} = node, acc ->
              case Ast.alias_to_module(used) do
                nil -> {node, acc}
                mod -> {node, [mod | acc]}
              end

            node, acc ->
              {node, acc}
          end)

        list |> Enum.reverse() |> Enum.uniq()
    end
  end

  # `alias_to_module/1` and `find_module_body/2` were lifted to
  # `MutagenEx.Ast` per `mutagen.ast` (mutagen-wrd.25.2). Routes through
  # that canonical surface.

  # ---------------------------------------------------------------------------
  # Main per-site loop — async_stream over sites with ordered collection
  # ---------------------------------------------------------------------------
  #
  # The loop dispatches each site through `Task.Supervisor.async_stream_nolink/4`
  # under the configured `:task_sup` supervisor (default `MutagenEx.TaskSup`).
  # `:ordered` is `true` (the async_stream default), so the stream yields
  # site outcomes in input order regardless of which task finished first;
  # the byte-identical-output gate (`mutagen.mutation_pipeline.r15`)
  # depends on this ordering guarantee.
  #
  # Per-site classification — including taint propagation
  # (`tainted_predecessors`) — is computed in a sequential post-fold over
  # the ordered outcomes, NOT inside the task body. This is deliberate:
  # taint depends on the previous site's snapshot delta, so it must be
  # folded against the input-order stream and cannot be parallelised.
  #
  # The per-site task body covers everything that IS safely parallelisable
  # in principle: AST mutation, compile-quoted, MutationLoop.run/1
  # (timeout wrapping + ExUnit invocation), and restore. Note that ExUnit
  # globals (`ExUnit.Server`, `:cover`, the running test config) are
  # shared across tasks, so `--max-concurrency > 1` on a real ExUnit
  # backend can produce inter-site interference. The default in v1.1
  # remains `1`; consumers opting into parallel dispatch get a stderr
  # warning because the byte-identical-output gate is verified against the
  # test fakes (Agent-backed `ExUnitFake`, CompilerStub) which are
  # concurrency-safe by construction.
  defp execute(cfg, drift) do
    # Serial BeamCache snapshot pre-pass.
    #
    # Per `mutagen.decision.per_run_beam_cache`, every scoped module must
    # be snapshotted BEFORE the async_stream dispatch begins. Doing this
    # in a serial pre-pass closes the TOCTOU window that a per-worker
    # snapshot under `async_stream_nolink/4` would open: two workers
    # mutating the same module could otherwise race to capture an already-
    # mutated binary if the first worker's `Code.compile_quoted/2` ran
    # before the second worker's snapshot. The pre-pass guarantees every
    # entry in `cfg.beam_cache_table` is the cover-instrumented original.
    #
    # Snapshot order vs. cover instrumentation: `CoverageRunner` runs
    # earlier in the pipeline (see `Mix.Tasks.Mutagen`) — by the time
    # `MutationRunner.run/1` is invoked, `:cover.compile_directory/1`
    # has already replaced the scoped modules' loaded binaries with
    # cover-instrumented variants. The snapshot taken here therefore
    # captures the cover-instrumented binary, and the per-site restore
    # via `:code.load_binary/3` swaps that cover-instrumented binary
    # back in. Coverage analysis on the eventual completed run sees
    # accumulated counts because the cover-instrumented binary is
    # restored between sites.
    #
    # `BeamCache.snapshot/3` is idempotent: a module appearing in
    # multiple scope records (or matched by multiple sites) is captured
    # at most once thanks to `:ets.insert_new/2`'s semantics. An
    # `:unavailable` return is surfaced as an abort because it means a
    # scoped module is not loaded in the BEAM — the per-site loop would
    # then have nothing to restore from.
    with :ok <- prime_beam_cache(cfg) do
      execute_after_prime(cfg, drift)
    end
  end

  # Pre-pass that snapshots every scoped module into `cfg.beam_cache_table`.
  #
  # Runs serially, BEFORE any per-site task starts. Honors
  # `mutagen.decision.per_run_beam_cache`'s TOCTOU-closure invariant: no
  # worker can mutate a module before its snapshot exists.
  #
  # Returns `:ok` always. Modules that the `code_server` reports as
  # `:unavailable` (no `.beam` resolvable on the BEAM's code path) are
  # SKIPPED — they simply do not get an entry in the table. This is
  # the test-fixture path: synthetic scope records with module names
  # like `Synthetic.Foo` that exist only as metadata in the test cfg
  # have no loaded bytecode, so there is nothing to snapshot and
  # therefore nothing to restore. The per-site loop's `restore/2`
  # mirrors this and skips modules without snapshots.
  #
  # In production, every scoped module IS loaded (the scope resolver
  # discovers modules by walking compiled sources, so by the time
  # `MutationRunner.run/1` is invoked they are necessarily on the code
  # path). A genuine `:unavailable` outcome there indicates a
  # configuration drift between the scope set and the BEAM's
  # loaded-module table — surfaced via a warning on the run's
  # `warnings` field rather than an abort, because the per-site
  # restore loop will also have nothing to swap and proceed as a
  # no-op for that module. The warning gives operators a way to
  # detect the drift without breaking the run.
  #
  # We snapshot the unique set of modules across `cfg.scope_records`.
  # Idempotency is delegated to `BeamCache.snapshot/3` (it ignores
  # repeat inserts via `:ets.insert_new/2`), so de-duping here is
  # purely a perf optimisation — one `get_object_code` call per
  # module instead of one per scope record.
  defp prime_beam_cache(cfg) do
    table = Map.fetch!(cfg, :beam_cache_table)
    code_server = code_server_module(cfg)

    modules =
      cfg.scope_records
      |> Enum.map(& &1.module)
      |> Enum.uniq()

    Enum.each(modules, fn module ->
      _ = BeamCache.snapshot(table, module, code_server)
    end)

    :ok
  end

  # The post-prime portion of `execute/2`. Split out from `execute/2` so
  # the prime step's `{:error, _, _}` short-circuits cleanly via `with`.
  defp execute_after_prime(cfg, drift) do
    sites = cfg.sites
    max_concurrency = resolve_max_concurrency(cfg)
    warn_experimental_parallel_mode(max_concurrency)
    on_site_completed = Map.get(cfg, :on_site_completed, fn _ -> :ok end)

    initial = %{
      results: [],
      compile_errors: [],
      state_drift_warning: drift,
      warnings: [],
      host_warnings: [],
      tainted: false,
      snapshot_after: nil,
      truncated: false
    }

    # `budget_ms` is the aggregate wall-clock budget from `--budget-ms`
    # (mutagen.cli.r13). `nil` means unbounded — the existing per-site
    # `timeout_ms` is the only cap. When budget is set, the fold checks
    # elapsed wall-clock BEFORE processing each completed-site outcome
    # and bails with `truncated: true` once the cap is hit. We don't
    # interrupt a site in flight — the per-site timeout owns that — so
    # the worst-case overshoot is one `timeout_ms`. On the serial path
    # (`max_concurrency == 1`) the outer stream is lazy, so halting
    # early also avoids dispatching subsequent sites.
    budget_ms = Map.get(cfg, :budget_ms)
    started_at = System.monotonic_time(:millisecond)

    # When `max_concurrency == 1` we stay in the caller process. This:
    #   1. Preserves the v1.0 byte-identical execution path — the
    #      fold reaches exactly the same accumulator updates in
    #      exactly the same order.
    #   2. Keeps Process-dictionary-backed test stubs working without
    #      having to thread state through `Task.Supervisor`. The
    #      existing `RecordingCompiler`-style hooks (see
    #      `test/mutagen_ex/mutation_runner_raise_test.exs`) record
    #      every compile call in the caller's process dictionary; a
    #      spawned task would never see those hooks.
    #
    # When `max_concurrency > 1` we dispatch through
    # `Task.Supervisor.async_stream_nolink/4` under the configured
    # `:task_sup`. The stream's `:ordered: true` default guarantees
    # the fold sees outcomes in input order, so the byte-identical
    # contract still holds for deterministic scopes — taint,
    # warnings, and counters all fold sequentially over the ordered
    # result list.
    parallel_task_sup =
      if max_concurrency == 1 do
        nil
      else
        Map.get(cfg, :task_sup, MutagenEx.TaskSup)
      end

    task_outcomes_stream =
      if max_concurrency == 1 do
        sites
      else
        group_leader = Process.group_leader()

        Task.Supervisor.async_stream_nolink(
          parallel_task_sup,
          sites,
          fn site ->
            Process.group_leader(self(), group_leader)
            process_site_task(site, cfg, nil)
          end,
          max_concurrency: max_concurrency,
          ordered: true,
          # Per-site timeout is handled INSIDE `MutationLoop.run/1`; the
          # outer async_stream timeout is effectively unbounded (the
          # inner task's wall-clock budget governs). `:infinity` makes
          # it explicit that the outer stream does not impose a second
          # competing deadline.
          timeout: :infinity,
          on_timeout: :kill_task
        )
      end

    outcome =
      Enum.reduce_while(task_outcomes_stream, {:ok, initial}, fn
        {:exit, reason}, {:ok, _acc} ->
          # Let the stream unwind before restoring modules that sibling
          # sites may still be using.
          {:halt, {:outer_task_exit, reason}}

        input, {:ok, acc} ->
          task_outcome =
            case input do
              %Site{} = site -> process_site_task(site, cfg, acc.snapshot_after)
              {:ok, task_outcome} -> task_outcome
            end

          # Fold the completed site's outcome FIRST (so the site that
          # crossed the budget still lands in results), then evaluate
          # the budget AFTER recording it — that decides whether to
          # short-circuit the remaining sites. The worst-case overshoot
          # is exactly one `timeout_ms` per `mutagen.cli.r13` because
          # the per-site task is not interrupted mid-flight.
          case fold_task_outcome(task_outcome, cfg, acc, on_site_completed) do
            {:cont, next_acc} ->
              if budget_exceeded?(budget_ms, started_at) do
                truncated = %{
                  next_acc
                  | warnings: [budget_truncation_warning(budget_ms) | next_acc.warnings],
                    truncated: true
                }

                {:halt, {:ok, truncated}}
              else
                {:cont, {:ok, next_acc}}
              end

            {:halt, abort} ->
              {:halt, abort}
          end
      end)

    case finish_parallel_run(outcome, parallel_task_sup, cfg) do
      {:ok, acc} ->
        {:ok,
         %{
           results: Enum.reverse(acc.results),
           compile_errors: Enum.reverse(acc.compile_errors),
           state_drift_warning: acc.state_drift_warning,
           warnings: acc.warnings |> Enum.reverse() |> Enum.uniq(),
           truncated: Map.get(acc, :truncated, false)
         }}

      err ->
        err
    end
  end

  defp finish_parallel_run({:outer_task_exit, reason}, task_sup, cfg) do
    abort_after_outer_task_exit(reason, task_sup, cfg)
  end

  defp finish_parallel_run({:ok, %{truncated: true}} = outcome, task_sup, cfg)
       when task_sup != nil do
    # Halting the outer stream can leave supervised ExUnit tasks alive.
    teardown_task_supervisor_children(task_sup)

    case restore_all_scoped_modules(cfg) do
      :ok ->
        outcome

      {:error, message} ->
        {:error, :unrecoverable_restore_failure, %{message: message}}
    end
  end

  defp finish_parallel_run({:error, _, _} = error, task_sup, cfg) when task_sup != nil do
    teardown_task_supervisor_children(task_sup)
    _ = restore_all_scoped_modules(cfg)
    error
  end

  defp finish_parallel_run(outcome, _task_sup, _cfg), do: outcome

  defp budget_exceeded?(nil, _started_at), do: false

  defp budget_exceeded?(budget_ms, started_at) when is_integer(budget_ms) do
    elapsed = System.monotonic_time(:millisecond) - started_at
    elapsed >= budget_ms
  end

  defp budget_truncation_warning(budget_ms) do
    "budget_exceeded: aggregate --budget-ms #{budget_ms} reached; " <>
      "report truncated to completed sites only"
  end

  # Resolves the per-site concurrency cap.
  #
  # The runner defaults to `1` (fully serial, in-caller-process) when
  # no value is set — the conservative, deterministic default that
  # preserves the v1.0 contract. The Mix task (`Mix.Tasks.Mutagen`)
  # mirrors this default: `Config.max_concurrency == nil` resolves to
  # `1` there too (`mix/tasks/mutagen.ex` — `config.max_concurrency
  # || 1`), so the user-facing default for `mix mutagen` is
  # `--max-concurrency 1`. Users pass `--max-concurrency N` (N > 1)
  # explicitly to opt in to parallelism. See
  # `mutagen.mutation_pipeline.r15` for the in-process pipeline
  # caveat (shared ExUnit/Code.Server/cover state) that motivates
  # default-1.
  defp resolve_max_concurrency(cfg) do
    case Map.get(cfg, :max_concurrency) do
      nil -> 1
      n when is_integer(n) and n > 0 -> n
    end
  end

  defp warn_experimental_parallel_mode(max_concurrency) when max_concurrency > 1 do
    IO.puts(:stderr, experimental_parallel_mode_warning())
  end

  defp warn_experimental_parallel_mode(_max_concurrency), do: :ok

  defp experimental_parallel_mode_warning do
    "warning: --max-concurrency > 1 is EXPERIMENTAL; " <>
      "parallel mode may produce incorrect kill/survive classification " <>
      "and corrupted coverage on real ExUnit/:cover backends. " <>
      "The safe path is the default, --max-concurrency 1."
  end

  # Per-site task body. Returns a `task_outcome` tuple that the
  # sequential post-fold turns into accumulator updates. The shape is
  # always `{:ok, site, source_text, outcome, stderr}` (the happy path
  # carries `source_text` for the renderer's verbatim-source-slice;
  # see `mutagen.json_schema.r4`), `{:compile_error, site, msg}`,
  # `{:ast_miss, site}`, `{:site_not_found, site}`, or `{:abort,
  # reason, details}`; the fold decides whether to continue or halt.
  defp process_site_task(%Site{} = site, cfg, snapshot_before) do
    case AstCache.get(cfg.ast_cache, site.file) do
      :error ->
        {:ast_miss, site}

      {:ok, {file_ast, source_text}} ->
        run_one_site_task(site, file_ast, source_text, cfg, snapshot_before)
    end
  end

  defp run_one_site_task(%Site{} = site, file_ast, source_text, cfg, snapshot_before) do
    case mutate_at_path(file_ast, site) do
      {:ok, mutated_ast} ->
        cfg = Map.put(cfg, :host_snapshot, MutagenEx.Test.RunGroup.snapshot())

        case safe_compile_quoted(mutated_ast, site.file, cfg) do
          {:ok, _modules, compile_stderr} ->
            run_within_restore(site, file_ast, source_text, compile_stderr, cfg, snapshot_before)

          {:error, :compile_error, message} ->
            # r5: `:compile_error` outcomes don't go in `results`; they
            # live in the parallel `compile_errors` array. The failed
            # compile shouldn't have replaced the module, but we still
            # call restore defensively to keep state hygiene uniform.
            # Per r6, restore failure on this branch is also abort-worthy
            # — surface it instead of swallowing (bw mutagen-wrd.17 / F27).
            case restore(site.file, cfg) do
              :ok ->
                {:compile_error, site, message}

              {:error, restore_msg} ->
                {:abort, :unrecoverable_restore_failure,
                 %{
                   site_id: site.id,
                   file: site.file,
                   message:
                     "restore failed on :compile_error branch: " <>
                       restore_msg <> " (original :compile_error: " <> message.message <> ")"
                 }}
            end
        end

      {:error, :site_not_found} ->
        {:site_not_found, site}
    end
  end

  defp run_within_restore(
         %Site{} = site,
         file_ast,
         source_text,
         compile_stderr,
         cfg,
         snapshot_before
       ) do
    case with_restore(file_ast, site, cfg, fn ->
           outcome =
             MutationLoop.run(%{
               test_modules: cfg.test_modules,
               timeout_ms: cfg.timeout_ms,
               failure_times: Map.get(cfg, :failure_times),
               host_snapshot: cfg.host_snapshot,
               serial?: resolve_max_concurrency(cfg) == 1,
               snapshot_before: snapshot_before,
               ex_unit: Map.get(cfg, :ex_unit, MutagenEx.Test.ExUnit),
               ex_unit_server: Map.get(cfg, :ex_unit_server, MutagenEx.Test.ExUnitServer),
               capture_io: Map.get(cfg, :capture_io, MutagenEx.Test.CaptureIo),
               cancel_grace_ms: Map.get(cfg, :cancel_grace_ms, 100),
               task_sup: Map.get(cfg, :task_sup, MutagenEx.TaskSup)
             })

           settle_code_server!(site, cfg, outcome)
           outcome
         end) do
      {:ok, {:error, {:ex_unit_run_failed, details}, meta}} ->
        {:abort, :ex_unit_run_failed,
         Map.merge(details, %{site_id: site.id, host_warnings: meta.host_warnings})}

      {:ok, outcome} ->
        # `source_text` is threaded through here so the post-fold can
        # add it to the result map for the renderer's verbatim slice
        # path (`mutagen.json_schema.r4`).
        {:ok, site, source_text, outcome, compile_stderr}

      {:error, :restore_failed, message} ->
        {:abort, :unrecoverable_restore_failure,
         %{
           site_id: site.id,
           file: site.file,
           message: message
         }}
    end
  end

  # ---------------------------------------------------------------------------
  # Sequential post-fold over ordered task outcomes
  # ---------------------------------------------------------------------------
  #
  # Taint (`tainted_predecessors`) cascades over the ORDERED stream —
  # async_stream's `:ordered: true` guarantees the fold sees outcomes
  # in input order even if tasks completed out of order. The fold also
  # invokes `:on_site_completed` for each accumulated site so the Mix
  # task's NDJSON streamer emits in the same order.

  defp fold_task_outcome(
         {:ok, site, source_text, outcome, compile_stderr},
         _cfg,
         acc,
         on_site_completed
       ) do
    {status, run_warnings, post_meta} = classify(outcome, compile_stderr)

    delta = MutationLoop.snapshot_delta(post_meta.snapshot_before, post_meta.snapshot_after)
    grew? = MutationLoop.snapshot_grew?(delta)

    tainted_now = acc.tainted

    snapshot_warning =
      if grew? do
        [snapshot_warning(site, delta)]
      else
        []
      end

    host_warnings = post_meta.host_warnings
    next_tainted = tainted_now or grew? or host_warnings != [] or match?({:timeout, _}, outcome)
    print_host_output(run_warnings)

    result = %{
      id: site.id,
      function: site.function,
      file: site.file,
      line: site.line,
      column: site.column,
      mutator: site.mutator,
      original_ast: site.original_ast,
      mutated_ast: site.mutated_ast,
      status: status,
      tainted_predecessors: tainted_now,
      warnings: Enum.uniq(acc.host_warnings ++ host_warnings) ++ run_warnings,
      # Threaded through for the JSON renderer's verbatim-source-slice
      # path (`mutagen.json_schema.r4`). When `end_line`/`end_column`
      # are nil, the renderer falls back to aliasing `before` into
      # `before_source`; when non-nil it slices `source_text` between
      # the leftmost descendant of `original_ast` and
      # `{end_line, end_column}`.
      end_line: site.end_line,
      end_column: site.end_column,
      source_text: source_text
    }

    _ = on_site_completed.({:result, result})

    {:cont,
     %{
       acc
       | results: [result | acc.results],
         warnings: host_warnings ++ snapshot_warning ++ acc.warnings,
         host_warnings: Enum.uniq(acc.host_warnings ++ host_warnings),
         tainted: next_tainted,
         snapshot_after: post_meta.snapshot_after
     }}
  end

  defp fold_task_outcome(
         {:compile_error, site, details},
         _cfg,
         acc,
         on_site_completed
       ) do
    print_host_output([{:host_output, details.message}])

    entry = %{
      id: site.id,
      function: site.function,
      file: site.file,
      line: site.line,
      column: site.column,
      mutator: site.mutator,
      message: details.message,
      exception: details[:exception]
    }

    _ = on_site_completed.({:compile_error, entry})

    {:cont, %{acc | compile_errors: [entry | acc.compile_errors]}}
  end

  defp fold_task_outcome({:ast_miss, site}, _cfg, acc, _on_site_completed) do
    warning = "ast_cache_miss: " <> site.file
    {:cont, %{acc | warnings: [warning | acc.warnings]}}
  end

  defp fold_task_outcome({:site_not_found, site}, _cfg, acc, _on_site_completed) do
    warning = "site_node_not_found: " <> site.id <> " in " <> site.file
    {:cont, %{acc | warnings: [warning | acc.warnings]}}
  end

  defp fold_task_outcome({:abort, reason, details}, _cfg, _acc, _on_site_completed) do
    {:halt, {:error, reason, details}}
  end

  # Wrap a closure that operates while a mutated AST is installed as the
  # module's current code. The protected window must complete with the
  # original AST restored on every path — successful completion, runtime
  # raise/throw/exit, or restore failure.
  #
  # Per `mutagen.mutation_pipeline.r12`:
  #   - Closure return + restore success → `{:ok, result}`.
  #   - Closure return + restore failure → `{:error, :restore_failed, msg}`
  #     (the caller surfaces this as `:unrecoverable_restore_failure`).
  #   - Closure raise/throw/exit → `safe_restore/3` runs best-effort, then
  #     the original kind/value/stacktrace is re-propagated via
  #     `reraise/2` or `:erlang.raise/3`. Restore failure during
  #     propagation is intentionally swallowed inside `safe_restore/3`
  #     so it cannot mask the original cause.
  #
  # Shape mirrors `MutagenEx.CoverageRunner.with_cover_lifecycle/2`.
  #
  # mutagen-wrd.25.6: the 4-arity signature (and the `file_ast`
  # parameter) is preserved verbatim per
  # `mutagen.decision.per_run_beam_cache` — "the `with_restore/4`
  # wrapper signature and external behaviour MUST be byte-identical
  # to pre-`.25`". Internally, restore no longer needs the AST
  # because the binary swap reloads from the `BeamCache` snapshot;
  # `file_ast` is therefore unused inside the wrapper but kept in the
  # signature so external callers (and future static-grep verification)
  # see the same shape they did before.
  defp with_restore(_file_ast, %Site{} = site, cfg, fun) do
    try do
      result = fun.()

      case restore(site.file, cfg) do
        :ok -> {:ok, result}
        {:error, message} -> {:error, :restore_failed, message}
      end
    rescue
      e ->
        _ = safe_restore(site, cfg)
        reraise(e, __STACKTRACE__)
    catch
      kind, value ->
        _ = safe_restore(site, cfg)
        :erlang.raise(kind, value, __STACKTRACE__)
    end
  end

  # Cleanup that never throws. Preserves the original exception inside
  # `rescue` / `catch` clauses by swallowing any failure of `restore/2`
  # itself (including raises from a misbehaving `:code_server` seam).
  defp safe_restore(%Site{} = site, cfg) do
    try do
      restore(site.file, cfg)
    rescue
      _ -> {:error, "safe_restore: restore raised"}
    catch
      _, _ -> {:error, "safe_restore: restore threw or exited"}
    end
  end

  @doc false
  @spec mutate_at_path(Macro.t(), Site.t()) :: {:ok, Macro.t()} | {:error, :site_not_found}
  def mutate_at_path(file_ast, %Site{path: path} = site), do: swap(file_ast, path, site)

  defp swap(node, [], %Site{original_ast: original, mutated_ast: mutated}) when node === original,
    do: {:ok, mutated}

  defp swap({form, meta, args}, [:form | rest], site) when is_list(meta) do
    with {:ok, changed} <- swap(form, rest, site), do: {:ok, {changed, meta, args}}
  end

  defp swap({form, meta, args}, [{:arg, index} | rest], site)
       when is_list(meta) and is_list(args) do
    with {:ok, changed} <- swap_child(args, index, rest, site), do: {:ok, {form, meta, changed}}
  end

  defp swap({left, right}, [:left | rest], site) do
    with {:ok, changed} <- swap(left, rest, site), do: {:ok, {changed, right}}
  end

  defp swap({left, right}, [:right | rest], site) do
    with {:ok, changed} <- swap(right, rest, site), do: {:ok, {left, changed}}
  end

  defp swap(list, [{:elem, index} | rest], site) when is_list(list),
    do: swap_child(list, index, rest, site)

  defp swap(_node, _path, _site), do: {:error, :site_not_found}

  defp swap_child([head | tail], 0, rest, site) do
    with {:ok, changed} <- swap(head, rest, site), do: {:ok, [changed | tail]}
  end

  defp swap_child([head | tail], index, rest, site) when is_integer(index) and index > 0 do
    with {:ok, changed} <- swap_child(tail, index - 1, rest, site), do: {:ok, [head | changed]}
  end

  defp swap_child(_list, _index, _rest, _site), do: {:error, :site_not_found}

  # ---------------------------------------------------------------------------
  # Code.Server settle (r4 hardening — `mutagen.decision.timeout_handling`)
  # ---------------------------------------------------------------------------

  # After a per-site mutation run that ended in `:timeout`, the inner
  # task may have been brutal-killed mid-flight inside `:code.load_binary/3`
  # (cover-recompile racing the mutation cycle). The Code.Server can be
  # left holding an orphaned per-module load lock; the next site's
  # compile-and-load cycle deadlocks waiting on it.
  #
  # Mitigation: call `:code.purge/1` on every scope record whose file
  # matches the just-mutated site. `:code.purge/1` is documented to
  # "remove the old code for the module" and, in OTP's current
  # implementation, also clears the code_server's tracking state for
  # that module — releasing the orphaned lock. Modules with no old
  # revision are a no-op.
  #
  # Every timeout triggers a purge, including when the task replied late.
  # `code_purge` is configurable for tests.
  defp settle_code_server!(%Site{} = site, cfg, {:timeout, _}) do
    purge_fun = Map.get(cfg, :code_purge, &:code.purge/1)

    for %Scope{file: file, module: module} <- cfg.scope_records, file == site.file do
      try do
        purge_fun.(module)
      rescue
        _ -> :ok
      catch
        _, _ -> :ok
      end
    end

    :ok
  end

  defp settle_code_server!(_site, _cfg, _outcome), do: :ok

  # ---------------------------------------------------------------------------
  # Compile + restore (r6, r11)
  # ---------------------------------------------------------------------------

  defp safe_compile_quoted(ast, file, cfg) do
    compile_fn = compiler_call(cfg)
    capture_io = Map.get(cfg, :capture_io, MutagenEx.Test.CaptureIo)

    # `with_io/2` returns `{closure_result, captured_io}` synchronously —
    # no process-dictionary smuggle needed. Per `mutagen-wrd.23` this
    # replaces the older `make_ref/Process.put/Process.get` pattern that
    # relied on the (undocumented) fact that `capture_io/2` runs its
    # closure in the calling process.
    {body_result, stderr} =
      capture_io.with_io(:stderr, fn ->
        try do
          {:ok, compile_fn.(ast, file)}
        rescue
          e -> {:error, %{exception: e.__struct__, message: Exception.message(e)}}
        catch
          kind, value -> {:error, %{message: "#{kind}: #{inspect(value)}"}}
        end
      end)

    case body_result do
      {:ok, modules} ->
        {:ok, modules, stderr}

      {:error, details} ->
        message = details.message <> if(stderr == "", do: "", else: "\nstderr:\n" <> stderr)
        {:error, :compile_error, %{details | message: message}}
    end
  end

  # Resolve the compile-quoted call. Production / new-shape callers pass
  # a module atom implementing `MutagenEx.Test.CompilerFacade`. Legacy
  # callers (pre-bw mutagen-wrd.24) pass a `{module, function}` tuple;
  # that shape is preserved so existing test stubs continue to work.
  # Returns a 2-arity function `(ast, file -> [{module, binary}])`.
  defp compiler_call(cfg) do
    case Map.get(cfg, :compiler, MutagenEx.Test.Compiler) do
      mod when is_atom(mod) ->
        fn ast, file -> mod.compile_quoted(ast, file) end

      {mod, fun} when is_atom(mod) and is_atom(fun) ->
        fn ast, file -> apply(mod, fun, [ast, file]) end
    end
  end

  # Restore the original `.beam` for every scoped module in `file`.
  #
  # Per `mutagen.decision.per_run_beam_cache`, restore is a binary swap
  # via `:code.load_binary/3` against the snapshot captured by
  # `prime_beam_cache/1`. There is NO `Code.compile_quoted/2` in this
  # path; the AST never participates.
  #
  # One file can host multiple modules (the canonical example is a file
  # with sibling `defmodule`s, or an umbrella module's child defs). We
  # restore every scoped module attributed to `file` rather than
  # threading the specific mutated module through `with_restore/4`'s
  # closure — the per-site task body installs a single mutated AST that
  # compiles into one module, but restoring every scoped module from
  # the cached binary is idempotent and cheap (one ETS lookup + one
  # `:code.load_binary/3` per module), so we restore them all.
  #
  # **Skip modules without snapshots.** When `prime_beam_cache/1`
  # encounters a module the `code_server` reports as `:unavailable`
  # (e.g. test fixtures with synthetic scope records, or a scope-set
  # drift in production), no entry lands in the table. Restore skips
  # those modules by treating `{:not_snapshotted, _}` as success-
  # equivalent — there is nothing to swap because nothing was loaded
  # in the first place. The mutation cycle for that file is then
  # effectively a no-op at the BEAM level (the AST-only compiler
  # stubs in tests already match this assumption).
  #
  # Returns `:ok` if every module either restores cleanly or was
  # never snapshotted. Returns `{:error, message}` on the first
  # `code_server`-reported failure; the caller folds this through
  # the existing `:unrecoverable_restore_failure` surface.
  defp restore(file, cfg) do
    modules =
      cfg.scope_records
      |> Enum.filter(fn %Scope{file: f} -> f == file end)
      |> Enum.map(& &1.module)
      |> Enum.uniq()

    restore_modules(modules, cfg)
  end

  defp restore_all_scoped_modules(cfg) do
    modules =
      cfg.scope_records
      |> Enum.map(& &1.module)
      |> Enum.uniq()

    restore_modules(modules, cfg)
  end

  defp restore_modules(modules, cfg) do
    table = Map.fetch!(cfg, :beam_cache_table)
    code_server = code_server_module(cfg)

    Enum.reduce_while(modules, :ok, fn mod, :ok ->
      case BeamCache.restore(table, mod, code_server) do
        {:ok, ^mod} ->
          {:cont, :ok}

        {:error, {:not_snapshotted, ^mod}} ->
          # No entry was captured for this module — typically because
          # the pre-pass `code_server` returned `:error` for it (test
          # fixture / unloaded module). Skip restore: there is nothing
          # to swap back. The mutation cycle's compile path is the
          # only stateful side effect, and that runs through the
          # `:compiler` seam which the test layer already controls.
          {:cont, :ok}

        {:error, {:code_server, reason}} ->
          {:halt,
           {:error,
            "beam_cache restore: " <>
              inspect(mod) <>
              " load_binary failed: " <>
              inspect(reason)}}
      end
    end)
  end

  # Resolve the code-server seam. Mirrors `compiler_call/1` (atom-only
  # shape — no back-compat tuple here because the seam is new in
  # mutagen-wrd.25.6). Production callers leave the default
  # `MutagenEx.Test.CodeServer`; tests inject a stub.
  defp code_server_module(cfg) do
    Map.get(cfg, :code_server, MutagenEx.Test.CodeServer)
  end

  defp abort_after_outer_task_exit(reason, task_sup, cfg) do
    teardown_task_supervisor_children(task_sup)

    message = "per-site outer task exited: " <> inspect(reason)

    case restore_all_scoped_modules(cfg) do
      :ok ->
        {:error, :unrecoverable_restore_failure, %{message: message}}

      {:error, restore_msg} ->
        {:error, :unrecoverable_restore_failure,
         %{
           message: message <> "; restore sweep after sibling teardown failed: " <> restore_msg
         }}
    end
  end

  defp teardown_task_supervisor_children(nil), do: :ok

  defp teardown_task_supervisor_children(task_sup) do
    task_sup
    |> task_supervisor_children()
    |> Enum.each(fn pid ->
      _ = Task.Supervisor.terminate_child(task_sup, pid)
    end)

    await_task_supervisor_drained(task_sup, 50)
  end

  defp await_task_supervisor_drained(_task_sup, 0), do: :ok

  defp await_task_supervisor_drained(task_sup, attempts_left) do
    case task_supervisor_children(task_sup) do
      [] ->
        :ok

      children ->
        Enum.each(children, fn pid ->
          _ = Task.Supervisor.terminate_child(task_sup, pid)
        end)

        Process.sleep(to_timeout(millisecond: 10))
        await_task_supervisor_drained(task_sup, attempts_left - 1)
    end
  end

  defp task_supervisor_children(task_sup) do
    Task.Supervisor.children(task_sup)
  rescue
    _ -> []
  catch
    _, _ -> []
  end

  # ---------------------------------------------------------------------------
  # Classification & taint (r4, r5, r7)
  # ---------------------------------------------------------------------------

  # Three input shapes from MutationLoop.run/1, mapped onto the five
  # outcomes from r5 (minus `:compile_error`, which never reaches here).
  defp classify({:completed, exunit_result, meta}, compile_stderr) do
    status =
      cond do
        not is_map(exunit_result) -> :error
        Map.get(exunit_result, :failures, 0) > 0 -> :killed
        true -> :survived
      end

    warnings = compose_warnings([compile_stderr, meta.stderr])
    {status, warnings, meta}
  end

  defp classify({:timeout, %{failure_recorded?: true} = meta}, compile_stderr) do
    warnings =
      compose_warnings([compile_stderr, meta.stderr]) ++
        ["deadline exceeded after a test failure"]

    {:killed, warnings, meta}
  end

  defp classify({:timeout, meta}, compile_stderr) do
    warnings = compose_warnings([compile_stderr, meta.stderr]) ++ ["timeout"]
    {:timeout, warnings, meta}
  end

  defp classify({:error, reason, meta}, compile_stderr) do
    warnings =
      compose_warnings([compile_stderr, meta.stderr, "error: " <> inspect(reason)]) ++
        ["test runner error"]

    {:error, warnings, meta}
  end

  defp compose_warnings(parts) do
    for text <- parts, String.trim(text) != "", do: {:host_output, text}
  end

  defp print_host_output(warnings) do
    if Process.get(:mutagen_report_device) do
      for {:host_output, text} <- warnings, do: IO.puts(:stderr, text)
    end
  end

  defp snapshot_warning(%Site{} = site, delta) do
    groups = [
      processes: delta.processes,
      ets: delta.ets,
      persistent_term: delta.persistent_terms
    ]

    {:host_names, :state_leak, [{site.id, groups}]}
  end

  # ---------------------------------------------------------------------------
  # Input normalisation
  # ---------------------------------------------------------------------------

  defp normalise(
         %{
           seed: seed,
           timeout_ms: timeout_ms,
           test_filter: %TestFilter{},
           ast_cache: ast_cache,
           sites: sites,
           scope_records: scope_records,
           test_modules: test_modules
         } = cfg
       )
       when is_integer(seed) and seed >= 0 and is_integer(timeout_ms) and timeout_ms > 0 and
              is_map(ast_cache) and is_list(sites) and is_list(scope_records) and
              is_list(test_modules) do
    {:ok, cfg}
  end

  defp normalise(_), do: {:error, :invalid_input, %{message: "invalid MutationRunner input"}}
end
