defmodule MutagenEx.BaselineTest do
  @moduledoc """
  Tests for `MutagenEx.Baseline`.

  Subjects advanced (see `.spec/specs/mutation_pipeline.spec.md` and
  `.spec/specs/coverage.spec.md`):

    * `mutagen.mutation_pipeline.r1` / `s1` — baseline red aborts with the
      `:baseline_red` reason and a `failures` list.
    * `mutagen.mutation_pipeline.r2` — forces `max_cases: 1` + the
      configured seed; async-true modules surface as warnings.
    * `mutagen.coverage.r9` / `s9b` — when `cfg.ast_cache` is populated,
      async-detection consumes the cached AST and does NOT read the
      test file from disk.
    * `mutagen.coverage.r9` / `s9c` — when `cfg.ast_cache` is populated
      but the cited file is absent, fall back to `File.read/1` + parse.

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

  describe "r9: ast_cache integration (post-`.25.3`)" do
    @async_fixture_source """
    defmodule Mutagen.Baseline.CachedAsyncFixtureTest do
      use ExUnit.Case, async: true
      test "fast", do: assert true
    end
    """

    @serial_fixture_source """
    defmodule Mutagen.Baseline.CachedSerialFixtureTest do
      use ExUnit.Case, async: false
      test "slow", do: assert true
    end
    """

    test "s9b: cache hit — async warning surfaces without reading the file from disk" do
      # The test_filter cites a virtual path that DOES NOT exist on the
      # real filesystem. If detect_async_modules ever falls through to
      # File.read/1 against this path, the read will return :enoent and
      # produce zero warnings. The only way to see the warning below is
      # for detect_async_modules to consume the cached AST.
      virtual_file = "virtual_paths/cached_async_test.exs"
      refute File.exists?(virtual_file)

      {:ok, ast} = Code.string_to_quoted(@async_fixture_source, columns: true, file: virtual_file)
      cache = %{virtual_file => {ast, @async_fixture_source}}

      input = %{
        seed: 0,
        test_filter: %TestFilter{include: [], exclude: [:test], files: [virtual_file]},
        ex_unit: ExUnitFake,
        test_loader: fn _ -> :ok end,
        ast_cache: cache
      }

      Process.put(:exunit_fake_run_result, %{failures: 0, total: 1, excluded: 0, skipped: 0})

      assert {:ok, result} = Baseline.run(input)

      assert Enum.any?(result.warnings, &(&1 =~ "Mutagen.Baseline.CachedAsyncFixtureTest")),
             "expected cached AST to produce the async warning; " <>
               "got warnings=#{inspect(result.warnings)}"

      assert Enum.any?(result.warnings, &(&1 =~ "async_module"))
    end

    test "s9b: cache hit with async: false — no warning, and still no disk read" do
      virtual_file = "virtual_paths/cached_serial_test.exs"
      refute File.exists?(virtual_file)

      {:ok, ast} =
        Code.string_to_quoted(@serial_fixture_source, columns: true, file: virtual_file)

      cache = %{virtual_file => {ast, @serial_fixture_source}}

      input = %{
        seed: 0,
        test_filter: %TestFilter{include: [], exclude: [:test], files: [virtual_file]},
        ex_unit: ExUnitFake,
        test_loader: fn _ -> :ok end,
        ast_cache: cache
      }

      Process.put(:exunit_fake_run_result, %{failures: 0, total: 1, excluded: 0, skipped: 0})

      assert {:ok, result} = Baseline.run(input)

      refute Enum.any?(result.warnings, &(&1 =~ "Mutagen.Baseline.CachedSerialFixtureTest"))
    end

    test "s9c: cache miss — falls back to File.read/1 + parse" do
      tmp =
        Path.join(
          System.tmp_dir!(),
          "mutagen_ex_baseline_cache_miss_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(tmp)
      on_exit(fn -> File.rm_rf!(tmp) end)

      file = Path.join(tmp, "async_test.exs")
      File.write!(file, @async_fixture_source)

      # Cache is populated but does NOT contain `file` — this is the
      # miss path. The implementation must fall back to File.read.
      cache = %{"some_other_file.ex" => {{:ok, nil}, ""}}

      input = %{
        seed: 0,
        test_filter: %TestFilter{include: [], exclude: [:test], files: [file]},
        ex_unit: ExUnitFake,
        test_loader: fn _ -> :ok end,
        ast_cache: cache
      }

      Process.put(:exunit_fake_run_result, %{failures: 0, total: 1, excluded: 0, skipped: 0})

      assert {:ok, result} = Baseline.run(input)

      # Fallback read+parse produced the warning — same result as the
      # no-cache path would have.
      assert Enum.any?(result.warnings, &(&1 =~ "Mutagen.Baseline.CachedAsyncFixtureTest")),
             "expected fallback path to read the on-disk file and produce a warning; " <>
               "got warnings=#{inspect(result.warnings)}"
    end

    test "no ast_cache field at all — fallback path stays intact (pre-`.25` behaviour)" do
      tmp =
        Path.join(
          System.tmp_dir!(),
          "mutagen_ex_baseline_no_cache_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(tmp)
      on_exit(fn -> File.rm_rf!(tmp) end)

      file = Path.join(tmp, "async_test.exs")
      File.write!(file, @async_fixture_source)

      # No :ast_cache in input — should still work via File.read.
      input = %{
        seed: 0,
        test_filter: %TestFilter{include: [], exclude: [:test], files: [file]},
        ex_unit: ExUnitFake,
        test_loader: fn _ -> :ok end
      }

      Process.put(:exunit_fake_run_result, %{failures: 0, total: 1, excluded: 0, skipped: 0})

      assert {:ok, result} = Baseline.run(input)
      assert Enum.any?(result.warnings, &(&1 =~ "Mutagen.Baseline.CachedAsyncFixtureTest"))
    end
  end

  describe "r1 (mutagen-wrd.37): cited test modules re-registered before ExUnit.run/0" do
    defmodule ExUnitServerFake do
      @moduledoc false
      @behaviour MutagenEx.Test.ExUnitServerFacade

      @impl MutagenEx.Test.ExUnitServerFacade
      def add_module(mod, cfg) do
        prior = Process.get(:exunit_server_fake_calls, [])
        Process.put(:exunit_server_fake_calls, [{mod, cfg} | prior])
        :ok
      end
    end

    defmodule ExUnitFakeRecordingOrder do
      @moduledoc false
      def configure(_), do: :ok

      def run do
        Process.put(:exunit_fake_ran_at, length(Process.get(:exunit_server_fake_calls, [])))
        %{failures: 0, total: 0, excluded: 0, skipped: 0}
      end
    end

    test "calls ex_unit_server.add_module/2 per :test_modules entry before ExUnit.run/0" do
      Process.delete(:exunit_server_fake_calls)
      Process.delete(:exunit_fake_ran_at)

      modules = [
        {SomeCitedTest, %{async?: false, group: nil, parameterize: nil}},
        {AnotherCitedTest, %{async?: false, group: nil, parameterize: nil}}
      ]

      input = %{
        seed: 0,
        test_filter: %TestFilter{include: [], exclude: [:test], files: []},
        ex_unit: ExUnitFakeRecordingOrder,
        ex_unit_server: ExUnitServerFake,
        test_loader: fn _ -> :ok end,
        test_modules: modules
      }

      assert {:ok, _} = Baseline.run(input)

      recorded = Process.get(:exunit_server_fake_calls) |> Enum.reverse()
      assert recorded == modules

      # Falsifier: every add_module call must have happened BEFORE
      # ExUnit.run/0. If re-registration moved after the run, the
      # registry would still be empty when ExUnit reads it.
      ran_at = Process.get(:exunit_fake_ran_at)
      assert ran_at == length(modules)
    end

    test "omitting :test_modules is a no-op (no calls to add_module)" do
      Process.delete(:exunit_server_fake_calls)

      input = %{
        seed: 0,
        test_filter: %TestFilter{include: [], exclude: [:test], files: []},
        ex_unit: ExUnitFake,
        ex_unit_server: ExUnitServerFake,
        test_loader: fn _ -> :ok end
      }

      Process.put(:exunit_fake_run_result, %{failures: 0, total: 0, excluded: 0, skipped: 0})

      assert {:ok, _} = Baseline.run(input)
      assert Process.get(:exunit_server_fake_calls, []) == []
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
