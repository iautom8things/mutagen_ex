defmodule MutagenEx.ReportSummaryTest do
  use ExUnit.Case, async: true

  alias MutagenEx.{JsonReporter, JsonStreamer, ReportSummary}
  alias JsonReporter.Report

  @tag spec: "mutagen.json_schema.r36"
  test "three evaluated high-confidence survivors qualify, while two do not" do
    two = sites("two", [:survived, :survived])
    three = sites("three", [:survived, :survived, :survived])
    mixed = sites("mixed", [:survived, :survived, :survived, :killed])
    timed = sites("timed", [:survived, :survived, :timeout])
    low = %{site("two", 8, :survived) | mutator: :guard_drop}
    tainted = Map.put(site("tainted", 2, :survived), :tainted_predecessors, true)

    summary =
      report(two ++ three ++ mixed ++ timed ++ [low, tainted])["summary"]

    assert summary["verdict"] == "check_first"
    assert %{"status" => "partial", "uncovered" => 0, "unevaluated" => 1} = summary["checked"]

    assert [
             %{
               "function" => "Fixture.three/1",
               "file" => "lib/fixture.ex",
               "line" => 1,
               "kind" => "nothing_asserted",
               "counts" => %{"mutants" => 3, "survived" => 3, "executed" => 3}
             }
           ] = summary["check_first"]

    assert ["Fixture.mixed/1", "Fixture.tainted/1", "Fixture.timed/1", "Fixture.two/1"] ==
             summary["worth_a_look"] |> Enum.map(& &1["function"]) |> Enum.uniq() |> Enum.sort()

    assert summary["worth_a_look_omitted"] == 3
    assert %{"timeout" => 1, "count" => 1} = summary["unevaluated"]
    assert %{"killed" => 1, "survived" => 12} = summary["counts"]

    assert summary["notes"] == [
             %{"kind" => "tainted_predecessors", "count" => 1},
             %{"kind" => "low_confidence_survivors", "count" => 1}
           ]

    assert [%{"kill_rate" => rate, "killed" => 0} | _] = summary["by_function"]
    assert rate == 0.0

    assert %{"kill_rate" => 0.25, "function" => "Fixture.mixed/1"} =
             List.last(summary["by_function"])
  end

  @tag spec: "mutagen.json_schema.r36"
  test "only functions with exclusively probe-confirmed misses are marked not executed" do
    pending = [pending("not_reached", 11), pending("reached", 12)]
    reached = site("reached", 4, :survived)
    unrelated = site("other", 5, :survived)
    timeout = site("timed", 6, :timeout)
    pending = pending ++ [pending("timed", 13), %{pending("covered", 14) | reason: :not_run}]
    pending = pending ++ [%{pending("not_confirmed", 15) | execution: :cover}]
    classic = report([reached, unrelated, timeout], pending)["summary"]
    changed = report([reached, unrelated, timeout], pending, meta: since())["summary"]

    assert Enum.map(classic["check_first"], & &1["kind"]) == ["not_executed"]

    assert [
             %{
               "function" => "Fixture.not_reached/1",
               "kind" => "not_executed",
               "counts" => %{"executed" => 0, "mutants" => 1, "survived" => 0}
             }
           ] =
             changed["check_first"]

    assert Enum.map(changed["worth_a_look"], & &1["id"]) == [reached.id, unrelated.id]
    assert changed["verdict"] == "check_first"

    assert changed["checked"] == %{
             "status" => "partial",
             "total" => 8,
             "uncovered" => 4,
             "unevaluated" => 2
           }

    assert %{"count" => 6, "uncovered" => 4, "not_run" => 1, "timeout" => 1} =
             changed["unevaluated"]
  end

  @tag spec: "mutagen.json_schema.r36"
  test "changed findings sort by confidence, then file and line, and count survivors outside the diff" do
    a = %{site("arith", 4, :survived) | file: "lib/a.ex"}
    b = %{site("bool", 7, :survived) | file: "lib/a.ex", mutator: :boolean}
    c = %{site("third", 2, :survived) | file: "lib/b.ex", mutator: :else_removal}
    low = %{site("guard", 1, :survived) | file: "lib/a.ex", mutator: :guard_drop}
    away = [site("off_diff", 2, :survived), %{low | id: "away"}]
    visible = [a, b, c, low]
    meta = Map.put(since(), :changed_line_sites, MapSet.new(visible, & &1.id))
    doc = report(Enum.reverse(visible ++ away), [], meta: meta)

    assert Enum.map(doc["summary"]["worth_a_look"], & &1["id"]) == Enum.map(visible, & &1.id)
    assert List.last(doc["summary"]["worth_a_look"])["confidence"] == "low"
    assert doc["summary"]["notes"] == [%{"kind" => "off_changed_line_survivors", "count" => 2}]
    assert Enum.count(doc["mutation"]["results"], &(&1["status"] == "survived")) == 6
    assert doc["summary"]["verdict"] == "worth_a_look"

    assert %{"verdict" => "nothing_to_check", "worth_a_look" => [], "worth_a_look_omitted" => 0} =
             report(away, [], meta: meta)["summary"]

    assert %{"verdict" => "worth_a_look", "worth_a_look" => [%{"confidence" => "low"}]} =
             report([low | away], [], meta: meta)["summary"]
  end

  @tag spec: "mutagen.json_schema.r36"
  test "inconclusive functions with no probe hit stay out of check first" do
    results = sites("maybe", [:survived, :survived, :survived])
    pending = %{pending("maybe", 9) | reason: :could_not_tell, execution: :could_not_tell}
    summary = report(results, [pending], meta: since())["summary"]
    assert summary["check_first"] == []

    assert [%{"kind" => "execution_could_not_tell", "functions" => ["Fixture.maybe/1"]}] =
             summary["notes"]

    [first | rest] = results
    with_hit = report([Map.put(first, :execution, :probe) | rest], [pending], meta: since())
    assert [%{"kind" => "nothing_asserted"}] = with_hit["summary"]["check_first"]
  end

  @tag spec: "mutagen.json_schema.r36"
  test "ranks provisional precision then file and line and counts omitted sites" do
    ranked =
      [
        {:boolean, "lib/a.ex", 1},
        {:boolean, "lib/a.ex", 3},
        {:boolean, "lib/b.ex", 2},
        {:else_removal, "lib/a.ex", 1},
        {:result_tuple, "lib/a.ex", 1},
        {:compare, "lib/a.ex", 1},
        {:case_drop, "lib/a.ex", 1},
        {:literal, "lib/a.ex", 1},
        {:arith, "lib/a.ex", 1}
      ]
      |> Enum.with_index()
      |> Enum.map(fn {{mutator, file, line}, i} ->
        %{site("rank_#{i}", i, :survived) | mutator: mutator, file: file, line: line}
      end)

    results = Enum.reverse(ranked)
    summary = report(results, [], summary_max: 7)["summary"]

    assert Enum.map(summary["worth_a_look"], & &1["id"]) ==
             Enum.map(Enum.take(ranked, 7), & &1.id)

    assert summary["worth_a_look_omitted"] == 2

    assert %{"verdict" => "unranked_survivors", "worth_a_look" => [], "worth_a_look_omitted" => 9} =
             report(results, [], summary_max: 0)["summary"]
  end

  @tag spec: "mutagen.json_schema.r36"
  test "stream end matches the aggregate summary" do
    report = %Report{mutation: %{results: [site("survives", 2, :survived)]}}
    JsonStreamer.emit_end(fn line -> send(self(), {:end_line, decode(line)}) end, report)
    assert_receive {:end_line, %{"summary" => summary}}
    assert summary == JsonReporter.to_wire(report)["summary"]
  end

  @tag spec: "mutagen.json_schema.r36"
  test "distinguishes an empty changed plan, an interrupted run and a clean classic run" do
    assert report([])["summary"]["verdict"] == "nothing_to_check"

    assert report([], [], meta: put_in(since().since.runtime, 0))["summary"]["verdict"] ==
             "no_mutable_changes"

    assert %{"verdict" => "incomplete", "worth_a_look" => [], "check_first" => []} =
             report([site("narrow_only", 2, :survived)], [pending("pending", 9)],
               meta: since(),
               truncated: true
             )["summary"]
  end

  @tag spec: ["mutagen.json_schema.r31", "mutagen.json_schema.r36"]
  test "pending, unevaluated and truncated runs agree with the completeness signal" do
    killed = site("covered", 2, :killed)
    assert report([killed], [], meta: since())["summary"]["verdict"] == "nothing_to_check"

    for {results, pending, verdict} <- [
          {[killed], [pending("uncovered", 3)], "check_first"},
          {[site("timeout", 2, :timeout)], [], "nothing_to_check"},
          {[site("worth", 2, :survived), site("error", 3, :error)], [], "worth_a_look"}
        ] do
      assert %{
               "summary" => %{"verdict" => ^verdict, "checked" => %{"status" => "partial"}},
               "meta" => %{"complete" => true}
             } =
               report(results, pending, meta: since())
    end

    assert %{"summary" => %{"verdict" => "incomplete"}, "meta" => %{"complete" => false}} =
             report([killed], [], meta: since(), truncated: true)

    with_skip = %Report{mutation: %{results: [killed], skipped: [%{site_id: "skip"}]}}

    assert %{
             "verdict" => "nothing_to_check",
             "counts" => %{"skipped" => 1},
             "unevaluated" => %{"count" => 0}
           } =
             ReportSummary.build(with_skip)

    low = %{site("low", 3, :survived) | mutator: :pipeline}

    assert %{"verdict" => "low_confidence_survivors", "worth_a_look" => []} =
             report([low])["summary"]
  end

  @tag spec: "mutagen.json_schema.r36"
  test "a file that fails alone leads the verdict even with uncovered sites" do
    warnings = [{:escalation_rejected, :escalation_baseline_red, ["test/red_test.exs"]}]

    summary =
      report([], [pending("uncovered", 2)], meta: since(), warnings: warnings)["summary"]

    assert %{"verdict" => "baseline_red", "checked" => %{"status" => "partial"}} = summary

    assert [%{"kind" => "baseline_red_files", "files" => ["test/red_test.exs"]}] =
             summary["notes"]
  end

  @tag spec: "mutagen.json_schema.r36"
  test "ranks fully escalated survivors first and keeps incomplete ones out of check first" do
    fully_escalated = site("complete", 2, :survived)

    incomplete =
      for item <- sites("incomplete", [:survived, :survived, :survived]) do
        item
        |> Map.replace!(:mutator, :boolean)
        |> Map.put(:selection, %{steps_run: [:narrow], escalation_incomplete: true})
      end

    summary = report(incomplete ++ [fully_escalated])["summary"]
    assert summary["check_first"] == []

    assert [first | rest] = summary["worth_a_look"]
    assert first["id"] == fully_escalated.id
    refute Map.has_key?(first, "escalation_incomplete")
    assert Enum.map(rest, & &1["id"]) == Enum.map(incomplete, & &1.id)
    assert Enum.all?(rest, & &1["escalation_incomplete"])
  end

  @tag spec: "mutagen.json_schema.r36"
  test "a runner error already listed as pending counts once" do
    error = site("error", 2, :error)
    pending = Map.put(error, :reason, :not_run)
    report = %Report{mutation: %{results: [error], pending: [pending]}}

    assert %{"unevaluated" => %{"count" => 1, "error" => 1, "not_run" => 0}} =
             ReportSummary.build(report)
  end

  @tag spec: "mutagen.json_schema.r36"
  test "a marked kill counts and explains why its function is absent from check first" do
    survivors = sites("mixed", [:survived, :survived, :survived])
    selection = %{killed_at: :module, steps_run: [:narrow, :module], after_dropped_file: true}
    weak_kill = %{site("mixed", 5, :killed) | mutator: :pipeline}
    weak_kill = Map.put(weak_kill, :selection, selection)
    following_survivor = Map.put(site("another", 6, :survived), :selection, selection)

    meta =
      Map.put(since(), :escalation, [
        %{step: :module, files_added: [], dropped_after_load: 2},
        %{step: :function, files_added: []}
      ])

    summary = report([weak_kill, following_survivor | survivors], [], meta: meta)["summary"]

    assert summary["check_first"] == []
    assert %{"killed" => 1, "survived" => 4} = summary["counts"]

    assert summary["notes"] == [
             %{"kind" => "kills_after_dropped_file", "count" => 1},
             %{"kind" => "escalation_dropped_after_load", "count" => 2}
           ]
  end

  defp report(results, pending \\ [], opts \\ []) do
    opts =
      case opts[:meta] do
        %{since: _} = meta ->
          Keyword.put(
            opts,
            :meta,
            Map.put_new(meta, :changed_line_sites, MapSet.new(results, & &1.id))
          )

        _ ->
          opts
      end

    struct!(Report, Keyword.put(opts, :mutation, %{results: results, pending: pending}))
    |> JsonReporter.to_wire()
  end

  defp since, do: %{since: %{runtime: 6}, incomplete_reasons: []}

  defp pending(function, line) do
    site(function, line, :pending)
    |> Map.delete(:status)
    |> Map.merge(%{reason: :uncovered, execution: :probe})
  end

  defp sites(function, statuses) do
    statuses
    |> Enum.with_index(2)
    |> Enum.map(fn {status, line} -> site(function, line, status) end)
  end

  defp site(function, line, status) do
    %{
      id: "lib/fixture.ex:#{function}-#{line}:arith",
      function: "Fixture.#{function}/1",
      file: "lib/fixture.ex",
      line: line,
      definition_line: 1,
      column: 2,
      mutator: :arith,
      status: status,
      before: "x + 1",
      after: "x - 1"
    }
  end

  defp decode(iodata), do: iodata |> IO.iodata_to_binary() |> JSON.decode!()
end
