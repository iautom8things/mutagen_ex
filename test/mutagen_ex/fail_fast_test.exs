defmodule MutagenEx.FailFastTest do
  use ExUnit.Case, async: false

  alias MutagenEx.Test.ExUnitServer

  @fixture Path.expand("../fixtures/lane_project/fail_fast", __DIR__)
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
    ebin = Path.join(System.tmp_dir!(), "fail_fast_#{System.unique_integer([:positive])}")
    File.mkdir_p!(ebin)
    Code.append_path(ebin)

    File.cd!(@fixture, fn ->
      compiler_options = Code.compiler_options()

      try do
        Code.compiler_options(debug_info: true)

        assert {:ok, _, _} =
                 Kernel.ParallelCompiler.compile_to_path([@source], ebin,
                   return_diagnostics: true
                 )
      after
        Code.compiler_options(compiler_options)
      end

      Code.require_file(@tests)
      ExUnitServer.discard_pending_modules()
    end)

    on_exit(fn ->
      Code.delete_path(ebin)
      File.rm_rf!(ebin)
    end)

    :ok
  end

  setup %{scenario: scenario} do
    prior = Application.get_all_env(:ex_unit)

    start_supervised!(%{
      id: Probe,
      start: {Agent, :start_link, [fn -> {scenario, []} end, [name: Probe]]}
    })

    # Both a finite cap and custom formatters must survive all pipeline exits.
    ExUnit.configure(max_failures: 2, formatters: [])
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

  test "three consecutive kills stop early and the next survivor runs the full suite" do
    {full, full_traces, full_ms} = run_pipeline(["--no-fail-fast"])
    {capped, capped_traces, capped_ms} = run_pipeline([])

    assert full["meta"]["fail_fast"] == false
    assert capped["meta"]["fail_fast"] == true
    assert full["version"] == capped["version"] and capped["version"] == "1"
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

    if System.get_env("MUTAGEN_FAIL_FAST_TIMING") do
      IO.puts("Mutation phase, full suite: #{full_ms} ms. Fail-fast: #{capped_ms} ms.")
    end
  end

  @tag scenario: :after_failure
  test "a failed test followed by a slow test changes only timeout to killed" do
    {capped, capped_traces, _} = run_pipeline(["--timeout-ms", "600"])
    {full, full_traces, _} = run_pipeline(["--timeout-ms", "600", "--no-fail-fast"])

    assert [{id, "timeout"} | rest] = verdicts(full)
    assert [{^id, "killed"} | ^rest] = verdicts(capped)
    assert survivor_ids(full) == survivor_ids(capped)
    assert test_events(hd(full_traces)) == test_steps(:infinity)
    assert test_events(hd(capped_traces)) == [{:first, 1}]
  end

  @tag scenario: :before_failure
  test "a deadline before any recorded failure stays a timeout in both modes" do
    {capped, traces, _} = run_pipeline(["--timeout-ms", "600"])
    {full, _, _} = run_pipeline(["--timeout-ms", "600", "--no-fail-fast"])

    assert [{_, "timeout"}, {_, "killed"}, {_, "killed"}, {_, "survived"}] = verdicts(capped)
    assert verdicts(full) == verdicts(capped)
    assert hd(traces) == [{:first, 1}]
  end

  @tag scenario: :slow_cleanup
  test "a failure recorded before the deadline is a kill even if suite cleanup takes longer" do
    {capped, _, _} = run_pipeline(["--timeout-ms", "600"])
    {full, _, _} = run_pipeline(["--timeout-ms", "600", "--no-fail-fast"])

    assert [{id, "timeout"} | rest] = verdicts(full)
    assert [{^id, "killed"} | ^rest] = verdicts(capped)
    assert [first, second | _] = capped["mutation"]["results"]
    assert "deadline exceeded after a test failure" in first["warnings"]
    assert second["tainted_predecessors"]
  end

  @tag scenario: :budget
  test "a budget truncation preserves stream ordering and restores ExUnit configuration" do
    {output, _traces, _elapsed} = invoke(["--stream", "--budget-ms", "1"], 0)

    assert [start, result, finish, aggregate] =
             output |> String.split("\n", trim: true) |> Enum.map(&:json.decode/1)

    assert %{"kind" => "start", "total" => 4, "meta" => %{"fail_fast" => true}} = start
    assert %{"kind" => "end", "aborted" => false, "completed" => 1, "killed" => 1} = finish
    assert aggregate["mutation"]["results"] == [Map.drop(result, ["version", "kind"])]
    assert aggregate["meta"] == start["meta"]
    assert aggregate["truncated"]
  end

  @tag scenario: :red
  test "coverage reads later lines and the error document lists every baseline failure" do
    {output, nil, nil} = invoke([], 2)
    report = :json.decode(output)

    assert %{"aborted" => true, "abort_reason" => "baseline_red", "mutation" => :null} = report

    assert report["baseline"] == %{
             "failed" => 2,
             "passed" => 1,
             "failures" => [
               %{"module" => "FailFastFixture.EarlyTest", "name" => "test exact arithmetic"},
               %{
                 "module" => "FailFastFixture.EarlyTest",
                 "name" => "test checks arithmetic again"
               }
             ]
           }

    assert 5 in report["coverage"]["covered_lines"][@source]
    phase = test_steps(:infinity) ++ [{:stats, %{failures: 2, total: 3, excluded: 0, skipped: 0}}]
    assert Probe.drain() == phase ++ phase
  end

  test "the mutation phase restores a finite failure cap when it raises" do
    before = Map.new(Application.get_all_env(:ex_unit))

    assert_raise RuntimeError, "mutation phase interrupted", fn ->
      MutagenEx.MutationRunner.run(%{
        seed: 0,
        timeout_ms: 600,
        test_filter: %MutagenEx.TestSelector.TestFilter{include: [], exclude: [], files: []},
        ast_cache: %{},
        sites: [],
        scope_records: [],
        test_modules: [],
        on_cache_built: fn _ ->
          assert Application.fetch_env!(:ex_unit, :max_failures) == 1
          raise "mutation phase interrupted"
        end
      })
    end

    assert Map.new(Application.get_all_env(:ex_unit)) == before
  end

  defp after_suite(stats) do
    if Process.whereis(Probe) do
      Probe.record({:stats, stats})

      if Probe.scenario() == :slow_cleanup and
           apply(FailFastFixture.Arithmetic, :first, [2, 3]) != 5 do
        Process.sleep(1500)
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
    before = Map.new(Application.get_all_env(:ex_unit))
    args = ["--scope", @source, "--tests", @tests, "--no-progress" | extra]
    dispatch = %{io: __MODULE__.Capture, mutation: __MODULE__.TraceMutation}
    Process.delete(:fail_fast_run)

    {{_result, stream}, _stderr} =
      ExUnit.CaptureIO.with_io(:stderr, fn ->
        ExUnit.CaptureIO.with_io(fn ->
          File.cd!(@fixture, fn -> Mix.Tasks.Mutagen.run(args, dispatch) end)
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
