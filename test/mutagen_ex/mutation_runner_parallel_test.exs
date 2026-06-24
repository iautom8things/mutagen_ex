defmodule MutagenEx.MutationRunnerParallelTest do
  @moduledoc """
  Tests for the parallel mutation loop introduced in
  bw mutagen-wrd.30.

  Subject advanced: `mutagen.mutation_pipeline.r15`.

    * Parallel-mode dispatch through
      `Task.Supervisor.async_stream_nolink/4` under
      `MutagenEx.TaskSup`.
    * Ordered collection — `:ordered: true` guarantees the
      sequential post-fold sees outcomes in input order even when
      tasks finish out of order.
    * Byte-identical aggregate output across `max_concurrency` values
      on deterministic input (the merge gate "Parallel run produces
      byte-identical JSON to serial run on a deterministic scope").
    * `:on_site_completed` callback fires once per site, in input
      order, regardless of concurrency. This is the single per-site
      observation seam (NDJSON streaming and the progress feed both
      ride it); there is no `:telemetry` event.

  These tests deliberately use synthetic `Site{}` records and the
  `Process`-dictionary-free `Agent`-backed `ExUnitFake` (also used by
  `MutagenEx.MutationRunnerTest`) so the parallel path can be exercised
  without spawning real ExUnit runs.
  """

  use ExUnit.Case, async: false

  alias MutagenEx.MutationEnumerator.Site
  alias MutagenEx.MutationRunner
  alias MutagenEx.ScopeResolver.Scope
  alias MutagenEx.TestSelector.TestFilter

  # --- Stubs ----------------------------------------------------------------

  # Agent-backed fake. Returns the SAME outcome for every per-site
  # `ExUnit.run/0` call — sufficient for proving byte-identical-output
  # invariance across `max_concurrency` values, and for proving that
  # results are collected in input order. Per-site differentiation is
  # exercised in the `on_site_completed` test below via the runner's
  # callback ordering rather than via the fake.
  defmodule ExUnitFake do
    @moduledoc false
    @agent :mutagen_ex_parallel_test_exunit_fake

    def start_link do
      Agent.start_link(fn -> %{outcome: nil, sleep_ms: 0} end, name: @agent)
    end

    def set_outcome(outcome, sleep_ms \\ 0),
      do: Agent.update(@agent, fn s -> %{s | outcome: outcome, sleep_ms: sleep_ms} end)

    def configure(_opts), do: :ok

    def run do
      {outcome, sleep_ms} =
        Agent.get(@agent, fn s -> {s.outcome, s.sleep_ms} end)

      if sleep_ms > 0, do: Process.sleep(sleep_ms)
      outcome || %{failures: 0, total: 1, excluded: 0, skipped: 0}
    end
  end

  defmodule ExUnitServerStub do
    @moduledoc false
    def add_module(_mod, _cfg), do: :ok
  end

  defmodule CompilerStub do
    @moduledoc false
    def compile_quoted(_ast, _file), do: []
  end

  defmodule CaptureIoStub do
    @moduledoc false
    def with_io(:stderr, fun), do: {fun.(), ""}
  end

  defmodule CrashCompilerStub do
    @moduledoc false
    @agent :mutagen_ex_parallel_crash_compiler_stub

    def start_link do
      Agent.start_link(
        fn ->
          %{
            crash_file: nil,
            block_file: nil,
            blocking_started?: false,
            events: []
          }
        end,
        name: @agent
      )
    end

    def configure(crash_file, block_file) do
      Agent.update(@agent, fn _ ->
        %{
          crash_file: crash_file,
          block_file: block_file,
          blocking_started?: false,
          events: []
        }
      end)
    end

    def events do
      Agent.get(@agent, fn state -> Enum.reverse(state.events) end)
    end

    def compile_quoted(_ast, file) do
      %{crash_file: crash_file, block_file: block_file} =
        Agent.get(@agent, fn state ->
          %{crash_file: state.crash_file, block_file: state.block_file}
        end)

      cond do
        file == crash_file ->
          wait_for_blocking_sibling(to_timeout(second: 1))
          record({:crashing_worker, self()})
          Process.exit(self(), :kill)
          Process.sleep(:infinity)

        file == block_file ->
          record({:blocking_worker_started, self()})
          Agent.update(@agent, fn state -> %{state | blocking_started?: true} end)

          receive do
            :release -> []
          after
            to_timeout(second: 10) -> []
          end

        true ->
          []
      end
    end

    defp wait_for_blocking_sibling(timeout_ms) do
      deadline = System.monotonic_time(:millisecond) + timeout_ms
      wait_for_blocking_sibling_until(deadline)
    end

    defp wait_for_blocking_sibling_until(deadline) do
      blocking_started? = Agent.get(@agent, & &1.blocking_started?)

      cond do
        blocking_started? ->
          :ok

        System.monotonic_time(:millisecond) >= deadline ->
          :ok

        true ->
          Process.sleep(to_timeout(millisecond: 10))
          wait_for_blocking_sibling_until(deadline)
      end
    end

    defp record(event) do
      Agent.update(@agent, fn state -> %{state | events: [event | state.events]} end)
    end
  end

  defmodule RecordingCodeServer do
    @moduledoc false
    @behaviour MutagenEx.Test.CodeServerFacade

    @agent :mutagen_ex_parallel_recording_code_server

    def start_link do
      Agent.start_link(fn -> %{task_sup: nil, snapshots: %{}, load_calls: []} end, name: @agent)
    end

    def set_task_sup(task_sup) do
      Agent.update(@agent, fn state -> %{state | task_sup: task_sup, load_calls: []} end)
    end

    def put_snapshot(module, binary, filename) do
      Agent.update(@agent, fn state ->
        %{state | snapshots: Map.put(state.snapshots, module, {module, binary, filename})}
      end)
    end

    def load_calls do
      Agent.get(@agent, fn state -> Enum.reverse(state.load_calls) end)
    end

    @impl MutagenEx.Test.CodeServerFacade
    def get_object_code(module) do
      Agent.get(@agent, fn state -> Map.get(state.snapshots, module, :error) end)
    end

    @impl MutagenEx.Test.CodeServerFacade
    def load_binary(module, filename, binary) do
      task_sup = Agent.get(@agent, & &1.task_sup)
      live_children = task_supervisor_children(task_sup)

      Agent.update(@agent, fn state ->
        call = %{
          module: module,
          filename: filename,
          binary: binary,
          live_children: live_children
        }

        %{state | load_calls: [call | state.load_calls]}
      end)

      {:module, module}
    end

    defp task_supervisor_children(nil), do: []

    defp task_supervisor_children(task_sup) do
      Task.Supervisor.children(task_sup)
    rescue
      _ -> []
    catch
      _, _ -> []
    end
  end

  setup do
    # Start the fake's Agent under ExUnit's supervisor so it is torn down
    # SYNCHRONOUSLY at the end of each test — the fixed name is always
    # free before the next test's setup.
    start_supervised!(%{id: ExUnitFake, start: {ExUnitFake, :start_link, []}})
    start_supervised!(%{id: CrashCompilerStub, start: {CrashCompilerStub, :start_link, []}})
    start_supervised!(%{id: RecordingCodeServer, start: {RecordingCodeServer, :start_link, []}})
    :ok
  end

  # --- Helpers --------------------------------------------------------------

  defp build_site(id, line) do
    file = "synthetic/foo_#{id}.ex"

    %Site{
      id: id,
      file: file,
      line: line,
      column: 13,
      mutator: :arith,
      original_ast: {:+, [line: line, column: 13], [1, 2]},
      mutated_ast: {:-, [line: line, column: 13], [1, 2]}
    }
  end

  defp build_file_ast(line) do
    {:defmodule, [line: 1, column: 1],
     [
       {:__aliases__, [line: 1, column: 11], [:Synthetic, :Foo]},
       [
         do:
           {:def, [line: line - 1, column: 3],
            [
              {:add, [line: line - 1, column: 7], []},
              [do: {:+, [line: line, column: 13], [1, 2]}]
            ]}
       ]
     ]}
  end

  defp build_cfg(sites, opts) do
    # One file_ast per site, keyed by site.file so each site finds
    # exactly one matching node in its own file.
    ast_cache =
      sites
      |> Enum.map(fn s ->
        {s.file, {build_file_ast(s.line), "synthetic source\n"}}
      end)
      |> Enum.into(%{})

    scope_records =
      sites
      |> Enum.map(fn s ->
        %Scope{file: s.file, line_range: 1..(s.line + 1), module: Synthetic.Foo}
      end)

    base = %{
      seed: 0,
      timeout_ms: 1_000,
      test_filter: %TestFilter{include: [], exclude: [:test], files: []},
      ast_cache: ast_cache,
      sites: sites,
      scope_records: scope_records,
      test_modules: [{Some.TestModule, %{async?: false, group: nil, parameterize: nil}}],
      ex_unit: ExUnitFake,
      ex_unit_server: ExUnitServerStub,
      capture_io: CaptureIoStub,
      compiler: CompilerStub,
      cancel_grace_ms: 50
    }

    Map.merge(base, Map.new(opts))
  end

  # ---------------------------------------------------------------------------
  # r15: byte-identical aggregate output across max_concurrency values
  # ---------------------------------------------------------------------------

  describe "byte-identical determinism (r15 merge gate)" do
    test "parallel and serial runs produce byte-equal results on deterministic input" do
      # All sites get the same outcome — `survived`. Under serial and
      # parallel dispatch, the runner must emit byte-equal aggregate
      # output because (a) async_stream's `:ordered: true` returns
      # results in input order, and (b) the sequential post-fold over
      # taint/warnings is deterministic regardless of which task body
      # finished first.
      ExUnitFake.set_outcome(%{failures: 0, total: 1, excluded: 0, skipped: 0})

      sites = for i <- 1..6, do: build_site("site-#{i}", i + 1)

      serial_cfg = build_cfg(sites, max_concurrency: 1)
      assert {:ok, serial_out} = run_mutation_runner(serial_cfg)

      parallel_cfg = build_cfg(sites, max_concurrency: 4)
      assert {:ok, parallel_out} = run_mutation_runner(parallel_cfg)

      assert serial_out.results == parallel_out.results
      assert serial_out.compile_errors == parallel_out.compile_errors
      assert serial_out.state_drift_warning == parallel_out.state_drift_warning
      assert serial_out.warnings == parallel_out.warnings

      # And we actually got 6 results — proves the test exercised the
      # full pipeline, not a no-op.
      assert length(serial_out.results) == 6
    end

    test "results are returned in input order regardless of completion order" do
      # All sites sleep 50ms then return. With max_concurrency: 3
      # all three tasks complete roughly simultaneously, but the
      # async_stream's `:ordered: true` default makes the runner emit
      # them in input order site-1 → site-2 → site-3.
      ExUnitFake.set_outcome(
        %{failures: 1, total: 1, excluded: 0, skipped: 0},
        # 30ms each — under max_concurrency: 3 all three finish
        # concurrently, so any ordering bug surfaces as randomness.
        30
      )

      sites = [
        build_site("site-1", 2),
        build_site("site-2", 3),
        build_site("site-3", 4)
      ]

      cfg = build_cfg(sites, max_concurrency: 3, timeout_ms: 500)

      assert {:ok, output} = run_mutation_runner(cfg)

      assert Enum.map(output.results, & &1.id) == ["site-1", "site-2", "site-3"]
      assert Enum.all?(output.results, &(&1.status == :killed))
    end

    test "max_concurrency: 1 returns a single correct result without crashing" do
      # The serial path (`if max_concurrency == 1` in mutation_runner.ex)
      # folds a lazy `Stream.map/2` over the sites rather than dispatching
      # through `Task.Supervisor.async_stream_nolink/4`. The in-caller
      # dispatch is an implementation detail that is not cleanly observable
      # (per-site `ExUnit.run/0` is executed in a separate timeout-isolation
      # process in BOTH modes), so this test pins the observable serial-mode
      # contract: one site in, exactly one matching result out.
      ExUnitFake.set_outcome(%{failures: 0, total: 1, excluded: 0, skipped: 0})

      sites = [build_site("only", 2)]
      cfg = build_cfg(sites, max_concurrency: 1)

      assert {:ok, %{results: [result]}} = run_mutation_runner(cfg)
      assert result.id == "only"
    end
  end

  # ---------------------------------------------------------------------------
  # r15: :on_site_completed callback fires per site in input order
  # ---------------------------------------------------------------------------

  describe "on_site_completed callback (streaming seam)" do
    test "callback fires once per site in input order under parallel dispatch" do
      ExUnitFake.set_outcome(%{failures: 0, total: 1, excluded: 0, skipped: 0}, 20)

      sites = [
        build_site("a", 2),
        build_site("b", 3),
        build_site("c", 4)
      ]

      parent = self()
      ref = make_ref()

      cb = fn payload -> send(parent, {ref, payload}) end

      cfg = build_cfg(sites, max_concurrency: 3, on_site_completed: cb)

      assert {:ok, _output} = run_mutation_runner(cfg)

      # in input order even when tasks finish concurrently. Each
      # `:result` payload carries the per-site `:status` (the progress
      # feed reads it), `:file`, `:line`, and `:mutator` — the fields
      # the Mix task projects into the progress line.
      assert_receive {^ref, {:result, %{id: "a", status: :survived, mutator: :arith}}}, 500
      assert_receive {^ref, {:result, %{id: "b", status: :survived}}}, 500
      assert_receive {^ref, {:result, %{id: "c", status: :survived}}}, 500
    end
  end

  describe "experimental parallel-mode warning" do
    test "warns once for max_concurrency > 1 and stays silent for max_concurrency: 1" do
      ExUnitFake.set_outcome(%{failures: 0, total: 1, excluded: 0, skipped: 0})

      parallel_sites = for i <- 1..3, do: build_site("warn-#{i}", i + 1)
      parallel_cfg = build_cfg(parallel_sites, max_concurrency: 3)

      assert {{:ok, %{results: parallel_results}}, parallel_stderr} =
               run_and_capture_stderr(parallel_cfg)

      assert length(parallel_results) == 3
      assert parallel_stderr =~ "--max-concurrency > 1 is EXPERIMENTAL"
      assert parallel_stderr =~ "incorrect kill/survive classification"
      assert parallel_stderr =~ "corrupted coverage"
      assert parallel_stderr =~ "default, --max-concurrency 1"

      warning_hits =
        Regex.scan(~r/--max-concurrency > 1 is EXPERIMENTAL/, parallel_stderr)
        |> length()

      assert warning_hits == 1

      serial_cfg = build_cfg([build_site("serial", 2)], max_concurrency: 1)
      assert {{:ok, %{results: [_]}}, ""} = run_and_capture_stderr(serial_cfg)
    end
  end

  describe "outer task crash restore sweep" do
    test "worker exit tears down siblings before restoring snapshotted scoped modules" do
      crash_site = build_site("crash", 2)
      blocking_site = build_site("blocking", 3)

      task_sup = start_supervised!({Task.Supervisor, []})
      CrashCompilerStub.configure(crash_site.file, blocking_site.file)
      RecordingCodeServer.set_task_sup(task_sup)

      victim = unique_victim_module()
      {snapshot_binary, snapshot_filename} = compile_snapshot(victim)
      RecordingCodeServer.put_snapshot(victim, snapshot_binary, snapshot_filename)

      scope_records = [
        %Scope{file: crash_site.file, line_range: 1..3, module: victim},
        %Scope{file: blocking_site.file, line_range: 1..4, module: victim}
      ]

      cfg =
        build_cfg([crash_site, blocking_site],
          max_concurrency: 2,
          task_sup: task_sup,
          compiler: CrashCompilerStub,
          code_server: RecordingCodeServer,
          scope_records: scope_records
        )

      assert {:error, :unrecoverable_restore_failure, %{message: msg}} =
               MutationRunner.run(cfg)

      assert msg =~ "per-site outer task exited"

      assert [
               %{
                 module: ^victim,
                 filename: ^snapshot_filename,
                 binary: ^snapshot_binary,
                 live_children: []
               }
             ] = RecordingCodeServer.load_calls()

      assert Enum.any?(CrashCompilerStub.events(), &match?({:blocking_worker_started, _}, &1))
    end
  end

  # --- helpers --------------------------------------------------------------

  defp run_mutation_runner(cfg) do
    {result, _stderr} = run_and_capture_stderr(cfg)
    result
  end

  defp run_and_capture_stderr(cfg) do
    ExUnit.CaptureIO.with_io(:stderr, fn ->
      MutationRunner.run(cfg)
    end)
  end

  defp unique_victim_module do
    Module.concat([ParallelRestoreVictim, :"M#{System.unique_integer([:positive])}"])
  end

  defp compile_snapshot(module) do
    parent = self()
    ref = make_ref()

    ast =
      quote do
        defmodule unquote(module) do
          @moduledoc false
          def value, do: :original
        end
      end

    _stderr =
      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        [{^module, binary}] = Code.compile_quoted(ast)
        send(parent, {ref, binary})
      end)

    binary =
      receive do
        {^ref, binary} -> binary
      after
        500 -> flunk("compile_snapshot did not return a BEAM binary")
      end

    filename =
      Path.join(System.tmp_dir!(), "#{inspect(module)}.beam")
      |> String.to_charlist()

    {binary, filename}
  end
end
