defmodule MutagenEx.FailFastTest do
  use ExUnit.Case, async: false

  alias MutagenEx.TestSelector.TestFilter

  @fixtures Path.expand("../fixtures/lane_project", __DIR__)
  @fixture Path.join(@fixtures, "fail_fast")
  @source "lib/arithmetic.ex"
  @tests "test/arithmetic_test.exs"
  @test_steps [:first, :same_module_tail, :next_module_tail]

  defmodule Probe do
    def record_test(step) do
      cap = Application.fetch_env!(:ex_unit, :max_failures)

      Agent.get_and_update(__MODULE__, fn {scenario, events} ->
        {scenario, {scenario, [{step, cap} | events]}}
      end)
    end

    def record(event) do
      Agent.update(__MODULE__, fn {scenario, events} -> {scenario, [event | events]} end)
    end

    def scenario, do: Agent.get(__MODULE__, &elem(&1, 0))

    def drain do
      Agent.get_and_update(__MODULE__, fn {scenario, events} ->
        {Enum.reverse(events), {scenario, []}}
      end)
    end
  end

  setup_all do
    compile_fixture(@fixture, @source)
    :ok
  end

  defp compile_fixture(root, source) do
    ebin = Path.join(System.tmp_dir!(), "fail_fast_#{System.unique_integer([:positive])}")
    File.mkdir_p!(ebin)
    Code.append_path(ebin)
    compiler_options = Code.compiler_options()

    on_exit(fn ->
      Code.delete_path(ebin)
      File.rm_rf!(ebin)
    end)

    try do
      Code.compiler_options(debug_info: true)

      File.cd!(root, fn ->
        assert {:ok, _, _} =
                 Kernel.ParallelCompiler.compile_to_path([source], ebin, return_diagnostics: true)
      end)
    after
      Code.compiler_options(compiler_options)
    end
  end

  setup %{scenario: scenario} do
    prior = Application.get_all_env(:ex_unit)

    start_supervised!(%{
      id: Probe,
      start: {Agent, :start_link, [fn -> {scenario, []} end, [name: Probe]]}
    })

    # Both a finite cap and custom formatters must survive all pipeline exits.
    ExUnit.configure(
      max_failures: 2,
      formatters: [],
      trace: false,
      slowest: 0,
      slowest_modules: 0
    )

    ExUnit.after_suite(&after_suite/1)

    on_exit(fn ->
      for {key, _} <- Application.get_all_env(:ex_unit), not Keyword.has_key?(prior, key) do
        Application.delete_env(:ex_unit, key)
      end

      ExUnit.configure(prior)
    end)

    :ok
  end

  @moduletag scenario: :normal

  @tag spec: ["mutagen.mutation_pipeline.r20", "mutagen.cli.r17", "mutagen.json_schema.r1"]
  test "three consecutive kills stop early and the next survivor runs the full suite" do
    {full, full_traces, _} = run_pipeline(["--no-fail-fast"])
    {capped, capped_traces, _} = run_pipeline([])

    assert full["meta"]["fail_fast"] == false
    assert capped["meta"]["fail_fast"] == true
    assert full["version"] == capped["version"] and capped["version"] == "2"
    assert verdicts(full) == verdicts(capped)
    assert survivor_ids(full) == survivor_ids(capped)
    assert Enum.map(verdicts(capped), &elem(&1, 1)) == ~w(killed killed killed survived)

    for trace <- Enum.take(capped_traces, 3) do
      assert trace == [{:first, 1}, {:stats, %{failures: 1, total: 1, excluded: 0, skipped: 0}}]
    end

    for trace <- Enum.take(full_traces, 3) do
      assert test_events(trace) == test_steps(:infinity)
      assert {:stats, %{failures: 2, total: 3}} = List.last(trace)
    end

    assert test_events(List.last(full_traces)) == test_steps(:infinity)
    assert test_events(List.last(capped_traces)) == test_steps(1)
    assert {:stats, %{failures: 0, total: 3}} = List.last(capped_traces) |> List.last()

    assert {{%{total: 0, failures: 0}, _output}, _stderr} =
             ExUnit.CaptureIO.with_io(:stderr, fn ->
               ExUnit.CaptureIO.with_io(fn -> ExUnit.run() end)
             end)
  end

  @tag :fail_fast_benchmark
  @tag scenario: :benchmark
  test "time mutation with a 100 ms trailing test" do
    {full, _, full_ms} = run_pipeline(["--no-fail-fast"])
    {capped, _, capped_ms} = run_pipeline([])
    assert verdicts(full) == verdicts(capped)
    IO.puts("Mutation phase, full suite: #{full_ms} ms. Fail-fast: #{capped_ms} ms.")
  end

  @tag scenario: :after_failure
  @tag spec: ["mutagen.mutation_pipeline.r4", "mutagen.mutation_pipeline.r20"]
  test "a failed test followed by a slow test changes only timeout to killed" do
    {capped, capped_traces, _} = run_pipeline(["--timeout-ms", "250"])
    {full, full_traces, _} = run_pipeline(["--timeout-ms", "250", "--no-fail-fast"])

    assert [{id, "timeout"} | rest] = verdicts(full)
    assert [{^id, "killed"} | ^rest] = verdicts(capped)
    assert survivor_ids(full) == survivor_ids(capped)
    assert test_events(hd(full_traces)) == test_steps(:infinity)
    assert test_events(hd(capped_traces)) == [{:first, 1}]
  end

  @tag scenario: :before_failure
  @tag spec: "mutagen.mutation_pipeline.r4"
  test "a deadline before any recorded failure stays a timeout in both modes" do
    {capped, traces, _} = run_pipeline(["--timeout-ms", "250"])
    {full, _, _} = run_pipeline(["--timeout-ms", "250", "--no-fail-fast"])

    assert [{_, "timeout"}, {_, "killed"}, {_, "killed"}, {_, "survived"}] = verdicts(capped)
    assert verdicts(full) == verdicts(capped)
    assert hd(traces) == [{:first, 1}]
  end

  @tag scenario: :slow_cleanup
  @tag spec: "mutagen.mutation_pipeline.r4"
  test "a failure recorded before the deadline is a kill even if suite cleanup takes longer" do
    {capped, _, _} = run_pipeline(["--timeout-ms", "250"])
    {full, _, _} = run_pipeline(["--timeout-ms", "250", "--no-fail-fast"])

    assert [{id, "timeout"} | rest] = verdicts(full)
    assert [{^id, "killed"} | ^rest] = verdicts(capped)
    assert [first, second | _] = capped["mutation"]["results"]
    assert "deadline exceeded after a test failure" in first["warnings"]
    assert second["tainted_predecessors"]
  end

  @tag scenario: :budget
  @tag spec: ["mutagen.cli.r13", "mutagen.json_schema.r14", "mutagen.mutation_pipeline.r2"]
  test "a budget truncation preserves stream ordering and restores ExUnit configuration" do
    {output, _traces, _elapsed} = invoke(["--stream", "--budget-ms", "1"], 0)

    assert [start, result, finish, aggregate] =
             output |> String.split("\n", trim: true) |> Enum.map(&:json.decode/1)

    assert %{"kind" => "start", "total" => 4, "meta" => %{"fail_fast" => true}} = start
    assert %{"kind" => "end", "aborted" => false, "completed" => 1, "killed" => 1} = finish
    assert aggregate["mutation"]["results"] == [Map.drop(result, ["version", "kind"])]
    assert Map.delete(aggregate["meta"], "timings_ms") == start["meta"]
    assert start["meta"] == finish["meta"]
    refute Map.has_key?(aggregate, "kind")
    refute Map.has_key?(result, "meta")
    assert aggregate["truncated"]
  end

  @tag scenario: :red
  @tag spec: ["mutagen.mutation_pipeline.r1", "mutagen.coverage.r4", "mutagen.json_schema.r16"]
  test "coverage reads later lines and the error document lists every baseline failure" do
    {output, nil, nil} = invoke([], 2)
    report = :json.decode(output)

    assert %{"aborted" => true, "abort_reason" => "baseline_red", "mutation" => :null} = report

    assert report["baseline"] == %{
             "failed" => 2,
             "passed" => 1,
             "failures" => [
               %{"module" => "FailFastFixture.EarlyTest", "count" => 2}
             ]
           }

    assert report["details"]["failures"] == report["baseline"]["failures"]
    assert 5 in report["coverage"]["covered_lines"][@source]
    phase = test_steps(:infinity) ++ [{:stats, %{failures: 2, total: 3, excluded: 0, skipped: 0}}]
    assert Probe.drain() == phase ++ phase
  end

  @tag spec: "mutagen.mutation_pipeline.r2"
  test "the mutation phase restores a finite failure cap when it raises" do
    before = Map.new(Application.get_all_env(:ex_unit))

    assert_raise RuntimeError, "mutation phase interrupted", fn ->
      MutagenEx.MutationRunner.run(%{
        seed: 0,
        timeout_ms: 250,
        test_filter: %MutagenEx.TestSelector.TestFilter{include: [], exclude: [], files: []},
        ast_cache: %{},
        sites: [],
        scope_records: [
          %MutagenEx.ScopeResolver.Scope{
            file: @source,
            line_range: 1..1,
            module: FailFastFixture.Arithmetic
          }
        ],
        test_modules: [],
        code_server: __MODULE__.InterruptingCodeServer
      })
    end

    assert Map.new(Application.get_all_env(:ex_unit)) == before
  end

  @tag spec: "mutagen.mutation_pipeline.r20"
  test "skipping another test's cleanup can kill later mutants that would survive" do
    fixture = fixture("fail_fast_state", "calc")
    on_exit(fn -> Application.delete_env(:fail_fast_state, :flag) end)

    full = run_fixture(fixture, ["--no-fail-fast"])
    refute Application.get_env(:fail_fast_state, :flag)
    capped = run_fixture(fixture, [])

    assert verdict_changes(full, capped) == [
             {"killed", "killed"},
             {"survived", "killed"},
             {"survived", "killed"}
           ]

    assert Application.get_env(:fail_fast_state, :flag)
  end

  @tag spec: "mutagen.mutation_pipeline.r20"
  test "skipping another test's cleanup can let a later mutant survive" do
    fixture = fixture("fail_fast_cleanup", "calc")
    Application.put_env(:fail_fast_cleanup, :strict, true)
    on_exit(fn -> Application.delete_env(:fail_fast_cleanup, :strict) end)

    full = run_fixture(fixture, ["--no-fail-fast"])
    assert Application.get_env(:fail_fast_cleanup, :strict)
    capped = run_fixture(fixture, [])

    assert [{"killed", "killed"}, {"killed", "survived"} | _] = verdict_changes(full, capped)
  end

  @tag spec: "mutagen.mutation_pipeline.r10"
  test "a formatter startup timeout drains ExUnit registrations for the next mutant" do
    fixture = fixture("fail_fast_drain", "num")
    ExUnit.configure(formatters: [__MODULE__.SlowFormatter])

    for mode <- [[], ["--no-fail-fast"]] do
      counter = :counters.new(1, [])
      ExUnit.configure(fail_fast_formatter_counter: counter)

      report =
        run_fixture(fixture, ["--timeout-ms", "150" | mode], %{mutation: __MODULE__.CountDrains})

      assert Process.delete(:fail_fast_drains) == 1
      assert Enum.map(verdicts(report), &elem(&1, 1)) == ~w(timeout killed killed)
      assert Enum.at(report["mutation"]["results"], 1)["tainted_predecessors"]
      assert :counters.get(counter, 1) == 5
      assert %{total: 0, failures: 0} = ExUnit.run()
    end
  end

  @tag spec: ["mutagen.mutation_pipeline.r1", "mutagen.mutation_pipeline.r10"]
  test "cold baseline records invalid tests and failed module teardown" do
    root = Path.join(@fixtures, "fail_fast_baseline")
    cfg = baseline_config(root, "test/shapes_test.exs")

    assert {:error, :baseline_red, %{failed: 4, passed: 1, failures: failures}} =
             MutagenEx.Baseline.run(cfg)

    assert Enum.sort(failures) == [
             {FailFastBaseline.PlainTest, :"test d fails"},
             {FailFastBaseline.SetupAllTest, :"test a"},
             {FailFastBaseline.SetupAllTest, :"test b"},
             {FailFastBaseline.TeardownTest, :"test c"}
           ]
  end

  @tag spec: [
         "mutagen.mutation_pipeline.r2",
         "mutagen.mutation_pipeline.r10",
         "mutagen.coverage.r4",
         "mutagen.coverage.r10"
       ]
  test "file configuration cannot override the phase options and survives afterward" do
    root = Path.join(@fixtures, "fail_fast_host")
    file = Path.join(root, "test/red_a_test.exs")
    cfg = baseline_config(root, "test/red_a_test.exs")

    {baseline, _io} = ExUnit.CaptureIO.with_io(fn -> MutagenEx.Baseline.run(cfg) end)
    assert {:error, :baseline_red, %{failed: 2, failures: [_, _]}} = baseline
    assert_host_settings()
    assert_run_settings(true)

    Code.unrequire_files([file])
    :code.purge(FailFastHost.RedATest)
    :code.delete(FailFastHost.RedATest)
    on_exit(fn -> Code.unrequire_files([file]) end)

    {coverage, _io} =
      ExUnit.CaptureIO.with_io(fn ->
        MutagenEx.CoverageRunner.run(Map.put(cfg, :in_scope_modules, []))
      end)

    assert {:ok, _} = coverage
    assert_host_settings()
    assert_run_settings(false)
  end

  @tag spec: ["mutagen.json_schema.r1", "mutagen.cli.r17"]
  test "early CLI errors still report the default mode" do
    assert {:aborted, :unknown_flag, _} =
             Mix.Tasks.Mutagen.run(["--bogus"], %{io: __MODULE__.Capture})

    assert_receive {:mutagen_output, 2, output}

    assert %{"version" => "2", "meta" => %{"id_scheme" => "2", "fail_fast" => true}} =
             :json.decode(output)
  end

  defp assert_host_settings do
    assert %{
             max_failures: 1,
             seed: 9,
             max_cases: 8,
             formatters: [ExUnit.CLIFormatter],
             include: [:host_only],
             exclude: [:test],
             timeout: 9_999
           } =
             Map.new(Application.get_all_env(:ex_unit))
  end

  defp assert_run_settings(collect_failures?) do
    assert [{:host_options, first}, {:host_options, second}, {:stats, %{total: 2, failures: 2}}] =
             Probe.drain()

    assert first == second

    assert %{
             max_failures: :infinity,
             seed: 0,
             max_cases: 1,
             include: [],
             exclude: [],
             timeout: 9_999
           } = first

    assert MutagenEx.Test.FailureFormatter in first.formatters == collect_failures?
    assert ExUnit.CLIFormatter in first.formatters
  end

  defp baseline_config(root, tests) do
    file = Path.join(root, tests)

    %{
      seed: 0,
      test_filter: %TestFilter{files: [file], include: [], exclude: []}
    }
  end

  defp fixture(name, basename) do
    root = Path.join(@fixtures, name)
    source = "lib/#{basename}.ex"
    tests = "test/#{basename}_test.exs"
    compile_fixture(root, source)
    {root, source, tests}
  end

  defp run_fixture(fixture, extra, dispatch \\ %{}) do
    {output, nil, nil} = invoke(extra, 0, fixture, dispatch)
    report = :json.decode(output)
    assert report["aborted"] == false
    assert report["mutation"]["compile_errors"] == []
    report
  end

  defp verdict_changes(full, capped) do
    assert Enum.map(verdicts(full), &elem(&1, 0)) == Enum.map(verdicts(capped), &elem(&1, 0))

    Enum.zip_with(verdicts(full), verdicts(capped), fn {_, before}, {_, after_status} ->
      {before, after_status}
    end)
  end

  defmodule InterruptingCodeServer do
    @behaviour MutagenEx.Test.CodeServerFacade

    import ExUnit.Assertions

    @impl MutagenEx.Test.CodeServerFacade
    def get_object_code(_module) do
      assert Application.fetch_env!(:ex_unit, :max_failures) == 1
      raise "mutation phase interrupted"
    end

    @impl MutagenEx.Test.CodeServerFacade
    def load_binary(_module, _filename, _binary), do: {:error, :unexpected_load}
  end

  defmodule SlowFormatter do
    use GenServer

    @impl GenServer
    def init(opts) do
      counter = Keyword.fetch!(opts, :fail_fast_formatter_counter)

      :counters.add(counter, 1, 1)
      if :counters.get(counter, 1) == 3, do: Process.sleep(500)

      {:ok, nil}
    end

    @impl GenServer
    def handle_cast(_, state), do: {:noreply, state}
  end

  defp after_suite(stats) do
    if Process.whereis(Probe) do
      Probe.record({:stats, stats})

      if Probe.scenario() == :slow_cleanup and
           apply(FailFastFixture.Arithmetic, :first, [2, 3]) != 5 do
        Process.sleep(800)
      end
    end
  end

  defp test_steps(cap), do: Enum.map(@test_steps, &{&1, cap})
  defp test_events(trace), do: Enum.reject(trace, &match?({:stats, _}, &1))

  defp run_pipeline(args) do
    {output, traces, elapsed} = invoke(args, 0)
    report = :json.decode(output)
    assert report["aborted"] == false
    assert report["baseline"]["passed"] == 3
    assert report["mutation"]["compile_errors"] == []
    {report, traces, elapsed}
  end

  defp invoke(extra, exit_code) do
    invoke(extra, exit_code, {@fixture, @source, @tests}, %{mutation: __MODULE__.TraceMutation})
  end

  defp invoke(extra, exit_code, {root, source, tests}, dispatch) do
    before = Map.new(Application.get_all_env(:ex_unit))
    args = ["--scope", source, "--tests", tests, "--no-progress" | extra]
    dispatch = Map.put(dispatch, :io, __MODULE__.Capture)
    Process.delete(:fail_fast_run)

    {{_result, stream}, _stderr} =
      ExUnit.CaptureIO.with_io(:stderr, fn ->
        ExUnit.CaptureIO.with_io(fn ->
          File.cd!(root, fn -> Mix.Tasks.Mutagen.run(args, dispatch) end)
        end)
      end)

    assert_receive {:mutagen_output, actual_exit, output}
    assert actual_exit == exit_code, output
    assert Map.new(Application.get_all_env(:ex_unit)) == before
    {traces, elapsed} = Process.get(:fail_fast_run, {nil, nil})
    {stream <> output, traces, elapsed}
  end

  defp verdicts(report), do: Enum.map(report["mutation"]["results"], &{&1["id"], &1["status"]})

  defp survivor_ids(report) do
    survivors = for {id, "survived"} <- verdicts(report), do: id
    IO.iodata_to_binary(:json.encode(survivors))
  end

  defmodule Capture do
    @behaviour MutagenEx.Pipeline.IoFacade

    @impl MutagenEx.Pipeline.IoFacade
    def emit(iodata, exit_code, _config) do
      send(self(), {:mutagen_output, exit_code, IO.iodata_to_binary(iodata)})
    end
  end

  defmodule CountDrains do
    @behaviour MutagenEx.Pipeline.MutationFacade
    @behaviour MutagenEx.Test.ExUnitServerFacade

    @impl MutagenEx.Pipeline.MutationFacade
    def run(cfg) do
      MutagenEx.MutationRunner.run(Map.put(cfg, :ex_unit_server, __MODULE__))
    end

    @impl MutagenEx.Test.ExUnitServerFacade
    defdelegate add_module(module, config), to: MutagenEx.Test.ExUnitServer

    @impl MutagenEx.Test.ExUnitServerFacade
    def discard_pending_modules do
      Process.put(:fail_fast_drains, Process.get(:fail_fast_drains, 0) + 1)
      MutagenEx.Test.ExUnitServer.discard_pending_modules()
    end
  end

  defmodule TraceMutation do
    @behaviour MutagenEx.Pipeline.MutationFacade

    @impl MutagenEx.Pipeline.MutationFacade
    def run(cfg) do
      stats = {:stats, %{failures: 0, total: 3, excluded: 0, skipped: 0}}
      phase = MutagenEx.FailFastTest.phase_events() ++ [stats]
      assert Probe.drain() == phase ++ phase

      Process.put(:fail_fast_traces, [])
      started = System.monotonic_time(:millisecond)

      result =
        MutagenEx.MutationRunner.run(%{
          cfg
          | on_site_completed: fn payload ->
              Process.put(:fail_fast_traces, [Probe.drain() | Process.get(:fail_fast_traces)])
              cfg.on_site_completed.(payload)
            end
        })

      elapsed = System.monotonic_time(:millisecond) - started
      Process.put(:fail_fast_run, {Enum.reverse(Process.delete(:fail_fast_traces)), elapsed})
      result
    end
  end

  def phase_events, do: test_steps(:infinity)
end
