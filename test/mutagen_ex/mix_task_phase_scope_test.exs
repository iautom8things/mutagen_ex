defmodule MutagenEx.MixTaskPhaseScopeTest do
  @moduledoc """
  Regression test for the `phase_scope` accumulator (bw mutagen-wrd.22 / F28).

  `phase_scope` reduces over `Config.scopes` calling the `:scope` dispatch
  collaborator for each, then concatenates the per-target record chunks
  into a single ordered list. The old implementation used `acc ++ records`
  which is O(|acc|) per call — quadratic over the cumulative record count.
  The fix prepends each chunk and flattens once at the end, dropping the
  total work to O(total_records).

  These tests exercise the Mix task's dispatch seam:

    * ordering across many targets stays input-order (linearity is allowed
      to reverse, but the user-observed contract is not — the spec says
      `Config.scopes` order is preserved through the pipeline);
    * a single `:scope` call returning a multi-record chunk preserves the
      chunk's internal order;
    * a large workload (2000 targets × 5 records = 10_000 records)
      completes in well under a second.

  The timing assertion is the falsifier for O(n²): the old code would
  perform ~50M `++` operations on this workload and take many seconds on
  modest hardware; the new code is linear. We set a generous 2_000 ms
  ceiling to leave headroom for slow CI runners while still falsifying
  the quadratic regression.
  """

  use ExUnit.Case, async: true

  alias MutagenEx.Config
  alias MutagenEx.ScopeResolver.Scope

  # Per bw mutagen-wrd.33, the Mix task's dispatch table carries plain
  # module atoms — tests swap modules, not `{module, function}` tuples.
  # The phase stubs below each implement their phase's
  # `MutagenEx.Pipeline.*Facade` behaviour. Their bodies read parameters
  # (target counts, captured-test-pid) from the process dictionary so
  # individual tests can vary behaviour without defining a new module
  # per test case.

  defmodule CliPassthrough do
    @moduledoc false
    # Bypass `MutagenEx.CLI.parse/1` so this test can drive an oversized
    # `Config.scopes` list past the `--scope` repetition cap
    # (`mutagen.cli.r12`). The cap is enforced at parse time and is the
    # right user-facing behaviour; for the phase_scope O(n) regression
    # we go directly to the orchestrator with a synthetic Config so we
    # can run the accumulator over thousands of targets and catch the
    # quadratic regression that the parse-time cap is *also* designed
    # to mask (caps + linear accumulator are layered defences against
    # the same F28 / F-PERF-12 finding).
    @behaviour MutagenEx.Pipeline.CliFacade

    @impl MutagenEx.Pipeline.CliFacade
    def parse(_argv) do
      case Process.get(:cli_passthrough_config) do
        %Config{} = config -> {:ok, config}
        _ -> {:error, :invalid_input, %{message: "no config in process dict"}}
      end
    end
  end

  defmodule PhaseScopeCollaborator do
    @moduledoc false
    # `:scope` collaborator. Returns `{:ok, [Scope{}]}` carrying
    # `records_per_target` records, each named after the target so we
    # can verify ordering downstream.
    @behaviour MutagenEx.Pipeline.ScopeFacade

    @impl MutagenEx.Pipeline.ScopeFacade
    def resolve(target, _opts) do
      count = Process.get(:records_per_target, 1)

      records =
        for i <- 1..count do
          %Scope{
            file: "lib/#{target}_#{i}.ex",
            line_range: 1..10,
            module: Module.concat([Mutagen.Synthetic, "T_#{target}_#{i}"])
          }
        end

      {:ok, records}
    end
  end

  defmodule PhaseScopeIo do
    @moduledoc false
    # A test-only `:io` collaborator: captures iodata + exit code so
    # the Mix task doesn't `System.halt/1` and we can inspect the final
    # report.
    @behaviour MutagenEx.Pipeline.IoFacade

    @impl MutagenEx.Pipeline.IoFacade
    def emit(iodata, code, _config) do
      send(Process.get(:capture_target), {:io, iodata, code})
      :ok
    end
  end

  defmodule PhaseTestsAbort do
    @moduledoc false
    # Aborting collaborator for the `:tests` phase. The phase_scope
    # tests never want phases after `:scope` to actually run; this stub
    # aborts with a predictable reason so the pipeline exits cleanly
    # after `phase_scope` finishes accumulating.
    @behaviour MutagenEx.Pipeline.TestsFacade

    @impl MutagenEx.Pipeline.TestsFacade
    def resolve(_targets, _opts) do
      {:error, :no_tests_match, %{message: "test harness — stop after scope"}}
    end
  end

  describe "phase_scope — order preservation (mutagen-wrd.22)" do
    setup do
      Process.put(:capture_target, self())
      Process.put(:records_per_target, 1)
      :ok
    end

    test "order across many targets is preserved (single-record per target)" do
      n = 50

      argv =
        Enum.flat_map(1..n, fn i -> ["--scope", "tgt#{i}"] end) ++
          ["--tests", "test/t_test.exs"]

      dispatch = %{
        scope: PhaseScopeCollaborator,
        tests: PhaseTestsAbort,
        io: PhaseScopeIo
      }

      assert {:aborted, :no_tests_match, report} =
               Mix.Tasks.Mutagen.run(argv, dispatch)

      # `report.scope` is the partial accumulated scope-records list at
      # the point of abort. With one record per target it must equal the
      # input target order.
      assert length(report.scope) == n

      observed_targets =
        Enum.map(report.scope, fn %Scope{file: file} ->
          # file shape is "lib/<target>_<i>.ex"
          file
          |> String.replace_prefix("lib/", "")
          |> String.replace_suffix("_1.ex", "")
        end)

      expected_targets = for i <- 1..n, do: "tgt#{i}"
      assert observed_targets == expected_targets
    end

    test "multi-record chunks preserve intra-chunk order (5 records per target)" do
      Process.put(:records_per_target, 5)

      argv = ["--scope", "a", "--scope", "b", "--tests", "test/t_test.exs"]

      dispatch = %{
        scope: PhaseScopeCollaborator,
        tests: PhaseTestsAbort,
        io: PhaseScopeIo
      }

      assert {:aborted, :no_tests_match, report} =
               Mix.Tasks.Mutagen.run(argv, dispatch)

      # 2 targets × 5 records each = 10 records, ordered:
      # a_1, a_2, ..., a_5, b_1, b_2, ..., b_5
      assert length(report.scope) == 10

      files = Enum.map(report.scope, & &1.file)

      assert files == [
               "lib/a_1.ex",
               "lib/a_2.ex",
               "lib/a_3.ex",
               "lib/a_4.ex",
               "lib/a_5.ex",
               "lib/b_1.ex",
               "lib/b_2.ex",
               "lib/b_3.ex",
               "lib/b_4.ex",
               "lib/b_5.ex"
             ]
    end
  end

  describe "phase_scope — O(n) performance regression (bw mutagen-wrd.22 / F-PERF-12)" do
    @tag :perf
    test "10_000 records across 2_000 targets completes well under the O(n^2) bound" do
      # Falsifies regression from the linear accumulator back to
      # `acc ++ records`. At 2000 targets × 5 records the old code does
      # roughly 5 * (0 + 5 + 10 + ... + 9995) ≈ 25M element copies for
      # `++`; on commodity hardware that comfortably exceeds 2 seconds.
      # The linear implementation completes in low double-digit
      # milliseconds. The 2_000 ms ceiling has plenty of headroom for
      # slow CI runners without giving the quadratic implementation any
      # room to pass.
      #
      # We bypass `CLI.parse/1` via the `:cli` dispatch seam so the
      # `--scope` repetition cap (which exists for a different reason —
      # bounding user input — see `mutagen.cli.r12`) doesn't intercept
      # this performance check.

      Process.put(:capture_target, self())
      Process.put(:records_per_target, 5)

      n_targets = 2_000

      synthetic_config = %Config{
        scopes: for(i <- 1..n_targets, do: "tgt#{i}"),
        tests: ["test/t_test.exs"]
      }

      Process.put(:cli_passthrough_config, synthetic_config)

      dispatch = %{
        cli: CliPassthrough,
        scope: PhaseScopeCollaborator,
        tests: PhaseTestsAbort,
        io: PhaseScopeIo
      }

      # Wall-clock the full pipeline call. `phase_scope` is the dominant
      # cost — all other phases are stubbed or trivial; the abort fires
      # immediately after `phase_tests` returns its error.
      {us, result} =
        :timer.tc(fn -> Mix.Tasks.Mutagen.run([], dispatch) end)

      ms = div(us, 1_000)

      assert {:aborted, :no_tests_match, report} = result
      assert length(report.scope) == n_targets * 5

      assert ms < 2_000,
             "phase_scope appears to be O(n^2) again: " <>
               "#{n_targets} targets × 5 records took #{ms}ms " <>
               "(expected < 2_000ms for an O(n) accumulator)"
    end
  end
end
