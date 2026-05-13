defmodule MutagenEx.Integration.C2Test do
  @moduledoc """
  C2 spike — proves repeated `ExUnit.run/0` invocations against the
  same loaded test module are stable in process and memory.

  Subjects advanced (see `.spec/specs/`):

  - `mutagen.mutation_pipeline.r10` — pipeline phases do not reload
    test modules between runs. Test files are loaded once via
    `Code.require_file/1`; subsequent runs reuse the same loaded code.
    C2 proves this contract holds even when the fixture's `setup_all`
    is aggressive (ETS table, named GenServer, `Application.put_env/3`).

  Fixture: `SpikeFixture.RateLimited` (defined inline in this test
  file because the fixture is a `use ExUnit.Case` module; living it
  outside `test/fixtures/spike_fixture/` would either pollute the
  default test run or require manual loading anyway).

  Invariants asserted across the 100-iteration loop:

  1. Every `ExUnit.run/0` reports `failures: 0`.
  2. `length(Process.list/0)` grows by at most 50 between baseline
     (before iteration 1) and end (after iteration 100).
  3. `:erlang.memory(:total)` stays ≤ 1.5× the baseline taken before
     iteration 1.

  Per the ticket's failure policy: negative outcome on the 100-iter
  loop escalates to the user. This test does not silently scope-
  restrict.
  """

  use ExUnit.Case, async: false

  @moduletag :spike
  @moduletag :integration

  @iterations 100

  # Inline ExUnit fixture test module. Stateful setup_all exercises
  # the three named-resource classes the spec calls out:
  # - ETS table
  # - named GenServer
  # - `Application.put_env/3` value
  # Each is created in setup_all and cleaned up in on_exit so re-
  # registering + re-running the module across 100 iterations does
  # not leak.
  defmodule RateLimited do
    use ExUnit.Case, register: false, async: false

    setup_all do
      table = :ets.new(:spike_rate_limit_counter, [:public, :named_table])
      :ets.insert(table, {:count, 0})

      {:ok, gs_pid} =
        Agent.start_link(fn -> 0 end, name: :spike_rate_limit_agent)

      :ok = Application.put_env(:spike_fixture, :rate_limit, 100)

      on_exit(fn ->
        # ETS: only the owner can delete. We use :public + a fresh
        # owner per setup_all, so the table lives until the owner
        # exits. Since setup_all runs in a temporary process that
        # exits at end of the suite run, the table auto-cleans. But
        # we belt-and-suspenders it here in case of leak.
        if :ets.info(:spike_rate_limit_counter) != :undefined do
          try do
            :ets.delete(:spike_rate_limit_counter)
          catch
            _, _ -> :ok
          end
        end

        if Process.alive?(gs_pid) do
          Agent.stop(gs_pid)
        end

        Application.delete_env(:spike_fixture, :rate_limit)
      end)

      {:ok, table: table, agent: gs_pid}
    end

    test "ETS table is reachable" do
      assert :ets.info(:spike_rate_limit_counter) != :undefined
      :ets.update_counter(:spike_rate_limit_counter, :count, 1)
      [{:count, n}] = :ets.lookup(:spike_rate_limit_counter, :count)
      assert n >= 1
    end

    test "named Agent is reachable" do
      assert Process.whereis(:spike_rate_limit_agent) != nil
      Agent.update(:spike_rate_limit_agent, &(&1 + 1))
      assert Agent.get(:spike_rate_limit_agent, & &1) >= 1
    end

    test "Application env is set" do
      assert Application.get_env(:spike_fixture, :rate_limit) == 100
    end
  end

  test "C2: 100 consecutive ExUnit.run/0 invocations against stateful fixture" do
    # Baseline samples taken BEFORE the loop. Per the ticket, the
    # process-count growth ceiling is "≤ 50" and the memory ceiling
    # is "≤ 1.5× baseline".
    process_baseline = length(Process.list())
    memory_baseline = :erlang.memory(:total)

    cfg = %{async?: false, group: nil, parameterize: nil}

    # Run the loop. Each iteration: register the fixture module,
    # invoke ExUnit.run/0, assert `failures: 0`. Capture ExUnit's own
    # output so the spike test's stdout is not flooded with 100
    # nested test-run banners.
    Enum.each(1..@iterations, fn iter ->
      ExUnit.CaptureIO.capture_io(fn ->
        ExUnit.Server.add_module(RateLimited, cfg)
        result = ExUnit.run()

        assert result.failures == 0,
               "GATING [iter #{iter}]: ExUnit.run/0 reported #{result.failures} " <>
                 "failures against the stateful fixture. Spec invariant " <>
                 "mutagen.mutation_pipeline.r10 broken."

        # Total must equal the number of tests we registered. If it
        # ever drops to 0 the registry got cleared between
        # `add_module` and `run/0` — would invalidate the iteration.
        assert result.total >= 3,
               "GATING [iter #{iter}]: expected at least 3 tests, got " <>
                 "#{inspect(result)}"
      end)
    end)

    process_end = length(Process.list())
    memory_end = :erlang.memory(:total)

    process_growth = process_end - process_baseline

    assert process_growth <= 50,
           "GATING: Process.list/0 grew by #{process_growth} (baseline " <>
             "#{process_baseline}, end #{process_end}). Spec limit is 50. " <>
             "Likely an `on_exit/1` leak in the fixture or an ExUnit-server " <>
             "process accumulation."

    memory_ratio = memory_end / memory_baseline

    assert memory_ratio <= 1.5,
           "GATING: :erlang.memory(:total) grew #{Float.round(memory_ratio, 3)}× " <>
             "(baseline #{memory_baseline}, end #{memory_end}). Spec ceiling " <>
             "is 1.5×."
  end
end
