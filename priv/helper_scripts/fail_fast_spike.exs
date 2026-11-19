# Run from the repository root with mix run priv/helper_scripts/fail_fast_spike.exs.

defmodule FailFastSpike do
  import ExUnit.Assertions

  def probe do
    ExUnit.start(autorun: false, formatters: [], max_cases: 1, seed: 0, max_failures: :infinity)
    {:ok, _pid} = Agent.start_link(fn -> [] end, name: __MODULE__)
    ExUnit.after_suite(&record({:stats, &1}))

    root = Path.expand("_build/fail_fast_spike_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)

    try do
      File.cd!(root, &run_fixture/0)
    after
      File.rm_rf!(root)
    end
  end

  def record(event), do: Agent.update(__MODULE__, &[event | &1])
  def drain, do: Agent.get_and_update(__MODULE__, &{Enum.reverse(&1), []})

  defp run_fixture do
    File.mkdir_p!("lib")
    File.mkdir_p!("test")
    File.mkdir_p!("ebin")
    source = "lib/fail_fast_fixture.ex"
    tests = "test/fail_fast_fixture_test.exs"

    File.write!(source, """
    defmodule FailFastSpike.Subject do
      def first(a, b), do: a + b
      def second(a, b), do: a - b
      def third(a, b), do: a * b
      def loose(a, b), do: a / b
    end
    """)

    File.write!(tests, """
    defmodule FailFastSpike.EarlyTest do
      use ExUnit.Case, async: true
      alias FailFastSpike.Subject

      test "exact arithmetic" do
        FailFastSpike.record(:first)
        assert Subject.first(2, 3) == 5
        assert Subject.second(4, 3) == 1
        assert Subject.third(2, 3) == 6
      end

      test "result is a number" do
        FailFastSpike.record(:same_module_tail)
        assert is_number(Subject.loose(2, 3))
      end
    end

    defmodule FailFastSpike.TailTest do
      use ExUnit.Case

      test "slow trailing test" do
        FailFastSpike.record(:next_module_tail)
        if :persistent_term.get({FailFastSpike, :timeout}, false) and
             FailFastSpike.Subject.first(2, 3) != 5 do
          Process.sleep(1500)
        else
          Process.sleep(100)
        end
      end
    end
    """)

    ebin = Path.expand("ebin")
    Code.append_path(ebin)

    assert {:ok, _, _} =
             Kernel.ParallelCompiler.compile_to_path([source], ebin, return_diagnostics: true)

    Code.require_file(tests)
    assert %{total: 3, failures: 0} = ExUnit.run()
    drain()

    first = run_scope(source, tests, :infinity, "2000")
    capped = run_scope(source, tests, 1, "2000")
    assert verdicts(first) == verdicts(capped)
    assert Enum.map(capped.results, & &1["status"]) == ~w(killed killed killed survived)
    assert Enum.all?(first.traces, &(test_events(&1) == all_tests()))

    for trace <- Enum.take(capped.traces, 3) do
      assert trace == [:first, {:stats, %{excluded: 0, failures: 1, skipped: 0, total: 1}}]
    end

    assert List.last(capped.traces) ==
             all_tests() ++ [{:stats, %{excluded: 0, failures: 0, skipped: 0, total: 3}}]

    IO.inspect(verdicts(capped), label: "same ordered ids and statuses with both caps")
    IO.inspect({first.mutation_ms, capped.mutation_ms}, label: "mutation ms, uncapped and capped")
    IO.puts("three consecutive max-failures runs returned failures=1, total=1")
    IO.puts("the following survivor ran all three tests, across both modules")

    :persistent_term.put({__MODULE__, :timeout}, true)
    capped_timeout = run_scope(source, tests, 1, "600")
    uncapped_timeout = run_scope(source, tests, :infinity, "600")
    assert [{id, "timeout"} | rest] = verdicts(uncapped_timeout)
    assert [{^id, "killed"} | ^rest] = verdicts(capped_timeout)
    assert List.first(uncapped_timeout.traces) == all_tests()
    assert [:first, {:stats, %{failures: 1, total: 1}}] = List.first(capped_timeout.traces)

    IO.inspect({id, "timeout", "killed"}, label: "counterexample, uncapped and capped")
  end

  defp run_scope(scope, tests, cap, timeout) do
    if Process.whereis(:cover_server), do: assert(:ok = :cover.stop())
    assert :infinity == Application.fetch_env!(:ex_unit, :max_failures)
    Process.put(:spike_cap, cap)

    args = ["--scope", scope, "--tests", tests, "--seed", "0", "--timeout-ms", timeout]
    dispatch = %{mutation: __MODULE__.Mutation, io: __MODULE__}

    output =
      ExUnit.CaptureIO.capture_io(fn -> assert :ok = Mix.Tasks.Mutagen.run(args, dispatch) end)

    report = :json.decode(output)
    assert report["aborted"] == false
    assert report["mutation"]["compile_errors"] == []
    assert report["baseline"]["passed"] == 3
    assert :infinity == Application.fetch_env!(:ex_unit, :max_failures)
    assert %{total: 0, failures: 0} = ExUnit.run()
    drain()

    %{
      mutation_ms: Process.get(:spike_mutation_ms),
      results: report["mutation"]["results"],
      traces: Enum.reverse(Process.get(:spike_traces))
    }
  end

  defp verdicts(run), do: Enum.map(run.results, &{&1["id"], &1["status"]})
  defp test_events(trace), do: Enum.filter(trace, &is_atom/1)
  defp all_tests, do: [:first, :same_module_tail, :next_module_tail]

  @behaviour MutagenEx.Pipeline.IoFacade
  @impl MutagenEx.Pipeline.IoFacade
  def emit(iodata, 0, _config), do: IO.write(iodata)

  defmodule Mutation do
    @behaviour MutagenEx.Pipeline.MutationFacade
    @impl MutagenEx.Pipeline.MutationFacade
    def run(cfg) do
      assert [
               :first,
               :same_module_tail,
               :next_module_tail,
               {:stats, %{failures: 0, total: 3}},
               :first,
               :same_module_tail,
               :next_module_tail,
               {:stats, %{failures: 0, total: 3}}
             ] = FailFastSpike.drain()

      Process.put(:spike_traces, [])
      prior = Application.fetch_env!(:ex_unit, :max_failures)
      ExUnit.configure(max_failures: Process.get(:spike_cap))
      started = System.monotonic_time(:millisecond)

      try do
        MutagenEx.MutationRunner.run(%{cfg | on_site_completed: &record_site(&1, cfg)})
      after
        Process.put(:spike_mutation_ms, System.monotonic_time(:millisecond) - started)
        ExUnit.configure(max_failures: prior)
      end
    end

    defp record_site(result, cfg) do
      Process.put(:spike_traces, [FailFastSpike.drain() | Process.get(:spike_traces)])
      cfg.on_site_completed.(result)
    end
  end
end

FailFastSpike.probe()
