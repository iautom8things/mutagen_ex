defmodule MutagenEx.MarkdownSummaryTest do
  use ExUnit.Case, async: true

  alias MutagenEx.{JsonReporter, MarkdownSummary}
  alias JsonReporter.Report

  @tag spec: "mutagen.json_schema.r37"
  test "clean changed run has a two-line golden" do
    assert_golden("summary_clean", report([site(2, :killed)], meta: since()))
  end

  @tag spec: "mutagen.json_schema.r37"
  test "check first only shows the definition line and a representative diff" do
    results = Enum.map(2..4, &site(&1, :survived))
    assert_golden("summary_check_first", report(results, meta: since()))
  end

  @tag spec: "mutagen.json_schema.r37"
  test "worth a look lists the best survivors up to the cap" do
    results = Enum.map(2..5, &site(&1, :survived, "fixture_#{&1}"))
    assert_golden("summary_worth_a_look", report(results, meta: since(), summary_max: 2))
  end

  @tag spec: "mutagen.json_schema.r37"
  test "incomplete notes explain the skipped evidence" do
    meta = %{
      since()
      | incomplete_reasons: [%{reason: :current_parse_error, path: "lib/broken.ex"}],
        since: %{since().since | unmapped: [%{path: "lib/fixture.ex", ranges: [[1, 1], [3, 5]]}]}
    }

    meta = Map.put(meta, :escalation, [%{step: :module, files_added: [], dropped_after_load: 1}])

    results = [
      site(2, :timeout),
      %{site(3, :survived) | mutator: :guard_drop} |> Map.put(:tainted_predecessors, true),
      Map.put(site(4, :killed), :selection, %{after_dropped_file: true})
    ]

    warnings = [
      {:escalation_rejected, :escalation_baseline_red, ["test/broken_test.exs"]},
      {:host_output, "DYNAMIC_HOST_CANARY"}
    ]

    assert_golden("summary_incomplete", report(results, meta: meta, warnings: warnings))
  end

  @tag spec: "mutagen.json_schema.r37"
  test "no-source removes source text from both formats and retains an opaque rerun" do
    doc = report([site(3, :survived)], meta: since(), source: false)
    [entry] = doc["summary"]["worth_a_look"]
    refute Map.has_key?(entry, "before_source")
    refute Map.has_key?(entry, "after")
    refute Map.has_key?(entry, "file")
    refute Map.has_key?(entry, "function")
    refute inspect(doc["summary"]) =~ "lib/fixture.ex"
    assert entry["rerun"] =~ ~r/--site [a-f0-9]{64}/
    assert_golden("summary_no_source", doc)
  end

  @tag spec: "mutagen.json_schema.r37"
  test "classic runs render the verdict without changed-code counts" do
    assert_golden("summary_classic", report([site(2, :killed), site(3, :survived)]))
  end

  @tag spec: "mutagen.json_schema.r37"
  test "timeouts keep coverage partial even when every evaluated mutant was killed" do
    doc = report([site(2, :killed), site(3, :timeout)], meta: since())
    assert doc["summary"]["verdict"] == "nothing_to_check"

    text = doc |> MarkdownSummary.render() |> IO.iodata_to_binary()

    assert text =~
             "**Mutagen found nothing to check.** 1 of 2 changed sites could not be checked."

    assert text =~ "1 unevaluated · kill rate 100.0% (1/1 evaluated)"
  end

  @tag spec: "mutagen.json_schema.r37"
  test "counts a budget-skipped file only once across passes" do
    one = "test/first_test.exs"
    two = "test/second_test.exs"
    reason = :escalation_budget_exhausted

    warnings = [
      {:escalation_rejected, reason, [one]},
      {:escalation_rejected, reason, [one, two, one]}
    ]

    doc = report([], warnings: warnings)

    assert [%{"kind" => "escalation_dropped", "count" => 2, "files" => [^one, ^two]}] =
             doc["summary"]["notes"]

    text = doc |> MarkdownSummary.render() |> IO.iodata_to_binary()
    assert text =~ "Skipped 2 test files during escalation"
    assert length(Regex.scan(~r/first_test\.exs/, text)) == 1
  end

  @tag spec: "mutagen.json_schema.r37"
  test "gives distinct wording for existing symlinks and submodules under source roots" do
    meta = %{
      incomplete_reasons: [
        %{reason: :preexisting_symlink, path: "lib/linked"},
        %{reason: :preexisting_gitlink, path: "lib/nested"}
      ]
    }

    text = [] |> report(meta: meta) |> MarkdownSummary.render() |> IO.iodata_to_binary()
    assert text =~ "did not read a symlink under the source root in `lib/linked`"
    assert text =~ "did not read a submodule under the source root in `lib/nested`"
  end

  @tag spec: "mutagen.json_schema.r37"
  test "headlines JSON survivors when every survivor has low confidence" do
    low = %{site(2, :survived) | mutator: :guard_drop}
    text = [low] |> report() |> MarkdownSummary.render() |> IO.iodata_to_binary()

    assert text =~ "**Mutagen found low-confidence survivors in the JSON (0 ranked).**"
  end

  @tag spec: "mutagen.json_schema.r40"
  test "timeout notes require three mutants and more than half the mutation wall time" do
    first = {0, 100}
    second = {75, 175}
    third = {200, 300}

    for {windows, wall_ms, note?} <- [
          {[first, second], 200, false},
          {[first, second, third], 550, false},
          {[first, second, third], 549, true}
        ] do
      results =
        for {{start, stop}, line} <- Enum.with_index(windows, 2) do
          window = {native_time(start), native_time(stop)}
          Map.put(site(line, :timeout), :timeout_window, window)
        end

      doc = report(results, meta: %{timings_ms: %{mutation: wall_ms}})
      expected = if note?, do: [%{"kind" => "mutation_timeouts_dominate", "count" => 3}], else: []
      assert doc["summary"]["notes"] == expected

      text = doc |> MarkdownSummary.render() |> IO.iodata_to_binary()
      assert String.contains?(text, "Consider `--timeout-ms` or `--budget-ms`") == note?
    end
  end

  @tag spec: "mutagen.json_schema.r38"
  test "names each escalation pass when their share of wall time exceeds half" do
    steps = [
      %{
        step: :module,
        wall_ms: 120,
        files_added: [],
        capped: false,
        survivors_in: 0,
        survivors_out: 0
      },
      %{
        step: :function,
        wall_ms: 35,
        files_added: [],
        capped: false,
        survivors_in: 0,
        survivors_out: 0
      }
    ]

    for {total, count} <- [{310, 0}, {309, 2}] do
      doc =
        report([], meta: %{timings_ms: %{total: total}, tests_selected: [], escalation: steps})

      assert length(doc["summary"]["notes"]) == count
      text = doc |> MarkdownSummary.render() |> IO.iodata_to_binary()
      assert String.contains?(text, "module escalation pass took 120 ms") == (count == 2)
      assert String.contains?(text, "function escalation pass took 35 ms") == (count == 2)
    end
  end

  defp assert_golden(name, doc) do
    path = Path.join([__DIR__, "golden", "#{name}.md"])
    actual = doc |> MarkdownSummary.render() |> IO.iodata_to_binary()

    if System.get_env("REGEN") == "1", do: File.write!(path, actual)

    assert actual == File.read!(path)
    refute actual =~ "DYNAMIC_HOST_CANARY"
  end

  defp report(results, opts) do
    struct!(Report, Keyword.put(opts, :mutation, %{results: results}))
    |> JsonReporter.to_wire()
  end

  defp report(results), do: report(results, [])

  defp native_time(ms), do: System.convert_time_unit(ms, :millisecond, :native)

  defp since do
    %{
      since: %{changed_files: 1, runtime: 4, base: String.duplicate("b", 40), unmapped: []},
      incomplete_reasons: []
    }
  end

  defp site(line, status, function \\ "fixture") do
    %{
      id: "lib/fixture.ex:#{String.pad_leading(to_string(line), 32, "0")}:arith",
      file: "lib/fixture.ex",
      function: "Fixture.#{function}/1",
      line: line,
      definition_line: 1,
      column: 3,
      mutator: :arith,
      status: status,
      before: "x + 1",
      before_source: "x + 1",
      after: "x - 1",
      excerpt_line: line
    }
  end
end
