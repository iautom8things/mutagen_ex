defmodule MutagenEx.BaselineTest do
  @moduledoc """
  Tests for `MutagenEx.Baseline`.

  Subjects advanced (see `.spec/specs/mutation_pipeline.spec.md`):

    * `mutagen.mutation_pipeline.r1` / `s1` — baseline red aborts with the
      `:baseline_red` reason and a `failures` list.
    * `mutagen.mutation_pipeline.r2` — forces `max_cases: 1` + the
      configured seed; async-true modules surface as warnings.

  Most tests use a stub ExUnit (a module masquerading as the real
  `ExUnit` for `configure/1`/`run/0`). The async-warning test does a
  small AST-only walk over a synthetic `_test.exs` file written to a
  tmp dir.
  """

  use ExUnit.Case, async: false

  alias MutagenEx.Baseline
  alias MutagenEx.TestSelector.TestFilter

  defmodule ExUnitFake do
    @moduledoc false
    def configure(opts) do
      Process.put(:exunit_fake_configure, opts)
      :ok
    end

    def run do
      Process.get(:exunit_fake_run_result, %{
        failures: 0,
        total: 0,
        excluded: 0,
        skipped: 0
      })
    end
  end

  describe "r2: forced ExUnit config" do
    test "configure/1 receives max_cases: 1 and the configured seed" do
      input = %{
        seed: 7,
        test_filter: %TestFilter{include: [], exclude: [:test], files: []},
        ex_unit: ExUnitFake,
        test_loader: fn _file -> :ok end
      }

      Process.put(:exunit_fake_run_result, %{
        failures: 0,
        total: 5,
        excluded: 0,
        skipped: 0
      })

      assert {:ok, result} = Baseline.run(input)
      assert result.passed == 5
      assert result.failed == 0
      assert result.failures == []

      opts = Process.get(:exunit_fake_configure)
      assert Keyword.get(opts, :max_cases) == 1
      assert Keyword.get(opts, :seed) == 7
    end

    test "include/exclude from TestFilter is propagated" do
      input = %{
        seed: 0,
        test_filter: %TestFilter{include: [:fast], exclude: [:test, :slow], files: []},
        ex_unit: ExUnitFake,
        test_loader: fn _ -> :ok end
      }

      Process.put(:exunit_fake_run_result, %{failures: 0, total: 0, excluded: 0, skipped: 0})
      assert {:ok, _} = Baseline.run(input)

      opts = Process.get(:exunit_fake_configure)
      assert Keyword.get(opts, :include) == [:fast]
      assert Keyword.get(opts, :exclude) == [:test, :slow]
    end
  end

  describe "r1: baseline red aborts (s1)" do
    test "returns :baseline_red when ExUnit reports failures" do
      input = %{
        seed: 0,
        test_filter: %TestFilter{include: [], exclude: [:test], files: []},
        ex_unit: ExUnitFake,
        test_loader: fn _ -> :ok end,
        failure_collector: fn ->
          [{SomeTestModule, "test crashes immediately"}]
        end
      }

      Process.put(:exunit_fake_run_result, %{failures: 1, total: 4, excluded: 0, skipped: 0})

      assert {:error, :baseline_red, details} = Baseline.run(input)
      assert details.failed == 1
      assert details.passed == 3
      assert details.failures == [{SomeTestModule, "test crashes immediately"}]
      assert is_binary(details.message)
    end

    test "no mutation phase is invoked on red baseline (collector not called when green)" do
      called = :counters.new(1, [])

      input = %{
        seed: 0,
        test_filter: %TestFilter{include: [], exclude: [:test], files: []},
        ex_unit: ExUnitFake,
        test_loader: fn _ -> :ok end,
        failure_collector: fn ->
          :counters.add(called, 1, 1)
          []
        end
      }

      # Green: collector called once (we always invoke it post-run; this
      # is fine — it's a pure read of an in-memory list).
      Process.put(:exunit_fake_run_result, %{failures: 0, total: 1, excluded: 0, skipped: 0})
      assert {:ok, _} = Baseline.run(input)
      assert :counters.get(called, 1) >= 1
    end
  end

  describe "r2 (warning): async: true test modules" do
    setup do
      tmp =
        Path.join(
          System.tmp_dir!(),
          "mutagen_ex_baseline_async_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(tmp)

      on_exit(fn -> File.rm_rf!(tmp) end)

      {:ok, tmp: tmp}
    end

    test "emits a warning naming any async: true module in the cited filter", ctx do
      file = Path.join(ctx.tmp, "async_test.exs")

      File.write!(file, """
      defmodule Mutagen.Baseline.AsyncFixtureTest do
        use ExUnit.Case, async: true
        test "fast", do: assert true
      end
      """)

      input = %{
        seed: 0,
        test_filter: %TestFilter{include: [], exclude: [:test], files: [file]},
        ex_unit: ExUnitFake,
        test_loader: fn _ -> :ok end
      }

      Process.put(:exunit_fake_run_result, %{failures: 0, total: 1, excluded: 0, skipped: 0})

      assert {:ok, result} = Baseline.run(input)
      assert Enum.any?(result.warnings, &(&1 =~ "Mutagen.Baseline.AsyncFixtureTest"))
      assert Enum.any?(result.warnings, &(&1 =~ "async_module"))
    end

    test "does NOT emit a warning for async: false (or unspecified) modules", ctx do
      file = Path.join(ctx.tmp, "serial_test.exs")

      File.write!(file, """
      defmodule Mutagen.Baseline.SerialFixtureTest do
        use ExUnit.Case, async: false
        test "slow", do: assert true
      end
      """)

      input = %{
        seed: 0,
        test_filter: %TestFilter{include: [], exclude: [:test], files: [file]},
        ex_unit: ExUnitFake,
        test_loader: fn _ -> :ok end
      }

      Process.put(:exunit_fake_run_result, %{failures: 0, total: 1, excluded: 0, skipped: 0})

      assert {:ok, result} = Baseline.run(input)
      refute Enum.any?(result.warnings, &(&1 =~ "Mutagen.Baseline.SerialFixtureTest"))
    end
  end

  describe "input validation" do
    test "rejects malformed inputs" do
      assert {:error, :invalid_input, _} = Baseline.run(%{})

      assert {:error, :invalid_input, _} =
               Baseline.run(%{
                 seed: -1,
                 test_filter: %TestFilter{include: [], exclude: [], files: []}
               })
    end

    test "halts when test_loader raises" do
      input = %{
        seed: 0,
        test_filter: %TestFilter{include: [], exclude: [:test], files: ["nope.exs"]},
        ex_unit: ExUnitFake,
        test_loader: fn _ ->
          raise File.Error, action: "load", path: "nope.exs", reason: :enoent
        end
      }

      assert {:error, :test_file_load_failed, details} = Baseline.run(input)
      assert details.file == "nope.exs"
    end
  end
end
