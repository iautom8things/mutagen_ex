defmodule MutagenEx.SelectedRunTest do
  use ExUnit.Case, async: true

  alias MutagenEx.{Config, SelectedRun, TestSelector}
  alias MutagenEx.JsonReporter.Report

  @tag spec: ["mutagen.mutation_pipeline.r28", "mutagen.json_schema.r28"]
  test "runner drops and covered sites without results stay pending, with fixed drop reasons" do
    covered_a = entry("a", "src/a.ex")
    covered_b = entry("b", "src/b.ex")
    uncovered = entry("c", "src/c.ex")
    entries = [covered_a, covered_b, uncovered]

    plan = %{
      sites: entries,
      selection: nil,
      meta: %{run: 0},
      incomplete: []
    }

    drops = [
      %{id: "a", reason: :site_node_not_found, path: covered_a.file},
      %{id: "b", reason: :ast_cache_miss, path: covered_b.file}
    ]

    config = %Config{scopes: [], tests: ["checks/a_test.exs"], since: "HEAD"}
    filter = %TestSelector.TestFilter{include: [], exclude: [], files: config.tests}
    report = %Report{meta: %{timings_ms: %{mutation: 0}}, warnings: []}

    coverage = %{
      covered_lines: %{covered_a.file => MapSet.new([2]), covered_b.file => MapSet.new([2])}
    }

    phases = %{
      coverage: fn _, _, report -> {:ok, coverage, report} end,
      test_input: fn _, _, _ -> {:ok, %{}} end,
      baseline: fn _, report -> {:ok, %{}, report} end,
      mutation: fn _, sites, _, report ->
        assert Enum.map(sites, & &1.id) == ["a", "b"]

        {:ok,
         %{
           results: [],
           compile_errors: [],
           dropped: drops,
           state_drift_warning: %{},
           warnings: []
         }, report}
      end
    }

    assert {:ok, report, outcome} = SelectedRun.run(plan, report, config, filter, [], phases)
    assert report.meta.incomplete == Enum.map(drops, &Map.delete(&1, :id))
    assert report.meta.since.run == 0

    assert Enum.map(outcome.pending, &{&1.id, &1.reason}) == [
             {"a", :not_run},
             {"b", :not_run},
             {"c", :uncovered}
           ]
  end

  defp entry(id, file) do
    %{
      id: id,
      file: file,
      line: 2,
      column: 1,
      mutator: :arith,
      original_ast: quote(do: x + 1),
      mutated_ast: quote(do: x - 1),
      path: [],
      fingerprint: String.duplicate("a", 32),
      in_scope: :changed_group
    }
  end
end
