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
