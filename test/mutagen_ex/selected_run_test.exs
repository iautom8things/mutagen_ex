defmodule MutagenEx.SelectedRunTest do
  use ExUnit.Case, async: false

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
    assert report.meta.incomplete_reasons == Enum.map(drops, &Map.delete(&1, :id))
    assert report.meta.since.run == 0
    refute Enum.any?(outcome.pending, &Map.has_key?(&1, :fingerprint))

    assert Enum.map(outcome.pending, &{&1.id, &1.reason}) == [
             {"a", :not_run},
             {"b", :not_run},
             {"c", :uncovered}
           ]
  end

  @tag :tmp_dir
  @tag spec: "mutagen.mutation_pipeline.r31"
  test "keeps explicit and budget-truncated runs out of escalation", %{tmp_dir: dir} do
    candidate = write_candidate(dir, "candidate")

    for {tests, truncated} <- [{["checks/narrow_test.exs"], false}, {["auto"], true}] do
      phases = callbacks(self(), candidate, truncated, :ok)
      {_report, outcome} = exercise(dir, tests, phases)
      assert [%{status: :survived, selection: %{steps_run: [:narrow]}}] = outcome.results
      refute_received {:candidate_baseline, _}
    end
  end

  @tag :tmp_dir
  @tag spec: "mutagen.mutation_pipeline.r31"
  test "preserves taint between passes and falls back to a green subset", %{tmp_dir: dir} do
    first = write_candidate(dir, "a")
    second = write_candidate(dir, "b")
    phases = callbacks(self(), first, false, {:red_combination, [first, second]})
    {report, outcome} = exercise(dir, ["auto"], phases)

    assert_received {:candidate_baseline, [^first, ^second]}
    assert_received {:escalation_taint, true}
    assert [step] = report.meta.escalation
    assert step.files_added == [first]
    assert step.baseline.passed == 2
    assert report.baseline.passed == 1

    assert [{:escalation_rejected, :escalation_baseline_red_in_combination, [^second]}] =
             report.warnings

    assert [%{status: :killed, selection: %{steps_run: [:narrow, :module]}}] = outcome.results
  end

  @tag :tmp_dir
  @tag spec: "mutagen.mutation_pipeline.r31"
  test "keeps narrow results when an escalation step itself fails", %{tmp_dir: dir} do
    candidate = write_candidate(dir, "candidate")
    phases = callbacks(self(), candidate, false, :coverage_abort)
    {report, outcome} = exercise(dir, ["auto"], phases)
    assert "escalation_failed" in report.warnings
    assert report.baseline.passed == 1
    assert [%{status: :survived, selection: %{steps_run: [:narrow]}}] = outcome.results
  end

  defp write_candidate(dir, name) do
    path = Path.join(dir, name <> "_test.exs")
    File.write!(path, "# Fixture.Store")
    Path.relative_to_cwd(path)
  end

  defp exercise(dir, tests, phases) do
    config = %Config{scopes: [], tests: tests, since: "HEAD"}
    file = "checks/narrow_test.exs"
    entry = Map.put(entry("id", "src/store.ex"), :function, "Fixture.Store.get/2")

    plan = %{
      sites: [entry],
      selection: [%{path: file, why: :convention}],
      meta: %{run: 0},
      incomplete: []
    }

    filter = %TestSelector.TestFilter{files: [file], include: [], exclude: []}
    report = %Report{meta: %{timings_ms: %{mutation: 0, baseline: 42}}, warnings: []}

    assert {:ok, result, outcome} =
             SelectedRun.run(plan, report, config, filter, [Path.relative_to_cwd(dir)], phases)

    {result, outcome}
  end

  defp callbacks(test, first, truncated, scenario) do
    coverage = %{covered_lines: %{"src/store.ex" => MapSet.new([2])}}
    narrow = ["checks/narrow_test.exs"]

    %{
      coverage: fn filter, _, report ->
        if scenario == :coverage_abort and filter.files != narrow do
          {:abort, report, nil, :coverage_timeout, %{}}
        else
          {:ok, coverage, report}
        end
      end,
      test_input: fn _, filter, _ -> {:ok, %{test_filter: filter}} end,
      baseline: fn %{test_filter: filter}, report ->
        files = filter.files
        if files != narrow, do: send(test, {:candidate_baseline, files})

        if scenario == {:red_combination, files} do
          {:abort, report, nil, :baseline_red, %{}}
        else
          baseline = %{passed: if(files == narrow, do: 1, else: 2), failed: 0, failures: []}
          {:ok, baseline, %{report | baseline: baseline}}
        end
      end,
      mutation: fn input, [site], _, report ->
        initial? = input.test_filter.files == narrow

        unless initial? do
          assert input.test_filter.files == [first]
          send(test, {:escalation_taint, input.tainted_predecessors})
        end

        status = if initial?, do: :survived, else: :killed
        result = %{id: site.id, status: status}

        {:ok,
         %{
           results: [result],
           compile_errors: [],
           warnings: [],
           state_drift_warning: %{},
           tainted: initial?,
           truncated: truncated
         }, report}
      end
    }
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
