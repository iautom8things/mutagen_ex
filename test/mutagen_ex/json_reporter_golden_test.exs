defmodule MutagenEx.JsonReporterGoldenTest do
  @moduledoc """
  Byte-exact golden-file tests for `MutagenEx.JsonReporter`.

  Covers scenario `mutagen.json_schema.s6` and verification stub
  `mutagen.json_schema.v3` and `mutagen.json_schema.r9`.

  Each test builds a `%Report{}` fixture, calls `JsonReporter.emit_report/1`
  or `emit_error/2`, and compares the produced iodata byte-for-byte against
  a checked-in fixture under `test/mutagen_ex/golden/`.

  ## Regenerating fixtures

  When the schema legitimately changes — every change here is a wire
  change, so it MUST be intentional — set `REGEN=1` and run the test
  suite. Each test then rewrites its fixture file on disk and skips the
  comparison. Without `REGEN=1`, fixture drift fails the build.

      REGEN=1 mix test test/mutagen_ex/json_reporter_golden_test.exs

  Six fixtures are required by `r9`:

    * `baseline_red.json`
    * `coverage_partial_mutation_perfect.json`
    * `coverage_full_mutation_partial.json`
    * `error_unresolvable_scope.json`
    * `mutation_with_skipped.json`
    * `partial_report_cover_failure.json`
  """

  use ExUnit.Case, async: true

  alias MutagenEx.JsonReporter
  alias MutagenEx.JsonReporter.Report

  @golden_dir Path.join([__DIR__, "golden"])

  # Regenerate fixtures when the env var is set. The test still asserts
  # the file was written (so a typo in the path surfaces).
  defp regen?, do: System.get_env("REGEN") == "1"

  defp assert_golden(fixture_name, iodata) do
    path = Path.join(@golden_dir, fixture_name)
    actual = IO.iodata_to_binary(iodata)

    if regen?() do
      File.mkdir_p!(@golden_dir)
      File.write!(path, actual)
      assert File.read!(path) == actual
    else
      expected =
        case File.read(path) do
          {:ok, content} ->
            content

          {:error, :enoent} ->
            flunk("missing golden fixture #{path}. Generate with REGEN=1 mix test")
        end

      if expected != actual do
        # Surface the diff in a usable form. flunk/1 truncates long strings,
        # so write the actual output to a sibling .actual file for easy
        # diffing.
        actual_path = path <> ".actual"
        File.write!(actual_path, actual)

        flunk(
          "golden fixture drift in #{Path.relative_to_cwd(path)}.\n" <>
            "Wrote actual output to #{Path.relative_to_cwd(actual_path)}.\n" <>
            "Diff: diff #{Path.relative_to_cwd(path)} #{Path.relative_to_cwd(actual_path)}"
        )
      end

      :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Shared meta — pinned so fixtures don't drift on host-specific values.
  # ---------------------------------------------------------------------------

  defp meta do
    %{
      tool_version: "0.1.0",
      elixir_version: "1.19.5",
      otp_version: "28",
      exunit_seed: 0
    }
  end

  defp test_filter do
    %{include: [], exclude: ["test"], files: ["test/foo_test.exs"]}
  end

  defp scope_record do
    %{file: "lib/foo.ex", line_range: 1..20, module: MyApp.Foo}
  end

  # ---------------------------------------------------------------------------
  # baseline_red.json — baseline phase failed, aborted: true
  # ---------------------------------------------------------------------------

  test "baseline_red.json — aborted with baseline failures populated (r9)" do
    report = %Report{
      meta: meta(),
      scope: [scope_record()],
      tests: test_filter(),
      baseline: %{
        "passed" => 4,
        "failed" => 1,
        "failures" => [%{"module" => "MyApp.FooTest", "name" => "computes wrong"}]
      },
      coverage: nil,
      mutation: nil,
      warnings: [],
      aborted: false,
      abort_reason: nil
    }

    {iodata, code} = JsonReporter.emit_error(report, :baseline_red)
    assert code != 0
    assert_golden("baseline_red.json", iodata)
  end

  # ---------------------------------------------------------------------------
  # coverage_partial_mutation_perfect.json — partial coverage, every site killed
  # ---------------------------------------------------------------------------

  test "coverage_partial_mutation_perfect.json — partial coverage, 100% kill rate" do
    report = %Report{
      meta: meta(),
      scope: [scope_record()],
      tests: test_filter(),
      baseline: %{passed: 8, failed: 0, failures: []},
      coverage: %{covered_lines: %{"lib/foo.ex" => [1, 2, 3, 4, 5]}},
      mutation: %{
        total: 3,
        completed: 3,
        killed: 3,
        survived: 0,
        timeout: 0,
        compile_error: 0,
        kill_rate: 1.0,
        results: [
          fixture_result("lib/foo.ex:111:arith", :arith, 5, 7, "1 + 2", "1 - 2", :killed),
          fixture_result("lib/foo.ex:222:bool", :bool, 8, 5, "true", "false", :killed),
          fixture_result("lib/foo.ex:333:comp", :comp, 12, 4, "a == b", "a != b", :killed)
        ],
        skipped: [],
        compile_errors: [],
        state_drift_warning: %{}
      },
      warnings: [],
      aborted: false,
      abort_reason: nil
    }

    {iodata, code} = JsonReporter.emit_report(report)
    assert code == 0
    assert_golden("coverage_partial_mutation_perfect.json", iodata)
  end

  # ---------------------------------------------------------------------------
  # coverage_full_mutation_partial.json — full coverage, mixed mutation outcomes
  # ---------------------------------------------------------------------------

  test "coverage_full_mutation_partial.json — mixed outcomes including timeout" do
    report = %Report{
      meta: meta(),
      scope: [scope_record()],
      tests: test_filter(),
      baseline: %{passed: 12, failed: 0, failures: []},
      coverage: %{covered_lines: %{"lib/foo.ex" => Enum.to_list(1..20)}},
      mutation: %{
        total: 5,
        completed: 5,
        killed: 3,
        survived: 1,
        timeout: 1,
        compile_error: 0,
        kill_rate: 0.6,
        results: [
          fixture_result("lib/foo.ex:101:arith", :arith, 2, 5, "a + b", "a - b", :killed),
          fixture_result("lib/foo.ex:102:arith", :arith, 3, 5, "a * b", "a / b", :killed),
          fixture_result("lib/foo.ex:103:bool", :bool, 7, 8, "x and y", "x or y", :survived),
          fixture_result(
            "lib/foo.ex:104:case_drop",
            :case_drop,
            9,
            3,
            "case x do\n  :a -> 1\n  _ -> 2\nend",
            "1",
            :killed
          ),
          fixture_result(
            "lib/foo.ex:105:arith",
            :arith,
            15,
            6,
            "loop()",
            "infinite_loop()",
            :timeout
          )
        ],
        skipped: [],
        compile_errors: [],
        state_drift_warning: %{}
      },
      warnings: [],
      aborted: false,
      abort_reason: nil
    }

    {iodata, code} = JsonReporter.emit_report(report)
    assert code == 0
    assert_golden("coverage_full_mutation_partial.json", iodata)
  end

  # ---------------------------------------------------------------------------
  # error_unresolvable_scope.json — `--scope` could not be resolved
  # ---------------------------------------------------------------------------

  test "error_unresolvable_scope.json — early abort, all sub-blocks null" do
    report = %Report{
      meta: meta(),
      scope: [],
      tests: nil,
      baseline: nil,
      coverage: nil,
      mutation: nil,
      warnings: [],
      aborted: false,
      abort_reason: nil
    }

    {iodata, code} = JsonReporter.emit_error(report, :module_not_found)
    assert code != 0
    assert_golden("error_unresolvable_scope.json", iodata)
  end

  # ---------------------------------------------------------------------------
  # mutation_with_skipped.json — scenario s2: 4 completed + 2 skipped + 1 compile_error
  # ---------------------------------------------------------------------------

  test "mutation_with_skipped.json — scenario s2 shape" do
    report = %Report{
      meta: meta(),
      scope: [scope_record()],
      tests: test_filter(),
      baseline: %{passed: 6, failed: 0, failures: []},
      coverage: %{covered_lines: %{"lib/foo.ex" => [1, 2, 3, 4, 5, 6, 7, 8]}},
      mutation: %{
        total: 4,
        completed: 4,
        killed: 3,
        survived: 1,
        timeout: 0,
        compile_error: 1,
        kill_rate: 0.75,
        results: [
          fixture_result("lib/foo.ex:k1:arith", :arith, 2, 5, "a + b", "a - b", :killed),
          fixture_result("lib/foo.ex:k2:arith", :arith, 3, 5, "x * y", "x / y", :killed),
          fixture_result("lib/foo.ex:k3:bool", :bool, 5, 7, "true", "false", :killed),
          fixture_result("lib/foo.ex:s1:arith", :arith, 6, 5, "p + q", "p - q", :survived)
        ],
        skipped: [
          %{
            site_id: "lib/foo.ex:sk1:arith",
            reason: :validate_refused,
            mutator: :arith,
            file: "lib/foo.ex"
          },
          %{
            site_id: "lib/foo.ex:sk2:case_drop",
            reason: :validate_refused,
            mutator: :case_drop,
            file: "lib/foo.ex"
          }
        ],
        compile_errors: [
          %{
            id: "lib/foo.ex:ce1:arith",
            file: "lib/foo.ex",
            line: 8,
            column: 5,
            mutator: :arith,
            message: "** (CompileError) badly typed AST"
          }
        ],
        state_drift_warning: %{}
      },
      warnings: [],
      aborted: false,
      abort_reason: nil
    }

    {iodata, code} = JsonReporter.emit_report(report)
    assert code == 0
    assert_golden("mutation_with_skipped.json", iodata)
  end

  # ---------------------------------------------------------------------------
  # partial_report_cover_failure.json — coverage phase failed; baseline ran
  # ---------------------------------------------------------------------------

  test "partial_report_cover_failure.json — partial run, cover phase failed" do
    report = %Report{
      meta: meta(),
      scope: [scope_record()],
      tests: test_filter(),
      baseline: nil,
      coverage: nil,
      mutation: nil,
      warnings: [],
      aborted: false,
      abort_reason: nil
    }

    {iodata, code} = JsonReporter.emit_error(report, :cover_already_running)
    assert code != 0
    assert_golden("partial_report_cover_failure.json", iodata)
  end

  # ---------------------------------------------------------------------------
  # Helper for building a result entry — keeps the fixture sites tidy.
  # ---------------------------------------------------------------------------

  defp fixture_result(id, mutator, line, col, before_str, after_str, status) do
    %{
      id: id,
      file: "lib/foo.ex",
      line: line,
      column: col,
      mutator: mutator,
      before: before_str,
      before_source: before_str,
      after: after_str,
      status: status,
      tainted_predecessors: status == :timeout,
      warnings: []
    }
  end
end
