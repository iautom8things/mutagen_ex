defmodule MutagenEx.ReportSummary do
  @moduledoc false

  alias MutagenEx.{JsonReporter, Mutators}
  alias JsonReporter.Sanitizer
  alias MutagenEx.MutationEnumerator.Site

  # Provisional order from docs/precision/blind-2026-11.csv. The arith
  # mutator has no measurement in that sample and ranks after literal.
  @precision ~w(boolean else_removal result_tuple compare case_drop literal arith)a
             |> Enum.with_index()
             |> Map.new()
  @function_cap 50

  def incomplete?(report) do
    report.aborted or report.truncated or
      (report.meta || %{})[:incomplete_reasons] not in [nil, []]
  end

  def build(report) do
    mutation = report.mutation || %{}
    meta = report.meta || %{}
    since = meta[:since]
    results = Map.get(mutation, :results, [])

    errors = Map.get(mutation, :compile_errors, [])
    completed = MapSet.new(results ++ errors, & &1.id)
    pending = Enum.reject(Map.get(mutation, :pending, []), &MapSet.member?(completed, &1.id))

    sites =
      Enum.map(results, &{&1.status, &1}) ++
        Enum.map(errors, &{:compile_error, &1}) ++
        Enum.map(pending, &{&1.reason, &1})

    counts = Enum.frequencies_by(sites, &elem(&1, 0))
    groups = group_functions(sites)

    interrupted? = report.aborted or report.truncated
    rejections = rejected_files(report.warnings)
    red = Map.get(rejections, :escalation_baseline_red, [])
    red_functions = Map.get(meta, :red_functions, MapSet.new())

    check_first =
      if interrupted?, do: [], else: check_first(groups, red_functions, report)

    hidden = MapSet.new(check_first, &elem(&1, 0))
    survivors = for {:survived, site} <- sites, do: site
    {high, low} = Enum.split_with(survivors, &high?/1)

    {candidates, away} =
      if since do
        changed_line_sites = Map.get(meta, :changed_line_sites, MapSet.new())
        Enum.split_with(survivors, &MapSet.member?(changed_line_sites, &1.id))
      else
        {high, []}
      end

    worth =
      if interrupted? do
        []
      else
        Enum.reject(candidates, fn site ->
          high?(site) and MapSet.member?(hidden, function_key(site)) and
            not escalation_incomplete?(site)
        end)
      end

    order = if since, do: &changed_rank/1, else: &rank/1
    ranked = worth |> Enum.sort_by(order) |> Enum.take(report.summary_max)
    total = length(sites)
    missing = max(0, Map.get(mutation, :planned_sites, total) - total)
    unevaluated = counts |> Map.update(:not_run, missing, &(&1 + missing)) |> unevaluated()

    verdict =
      cond do
        incomplete?(report) -> "incomplete"
        red != [] -> "baseline_red"
        check_first != [] -> "check_first"
        ranked != [] -> "worth_a_look"
        worth != [] -> "unranked_survivors"
        is_nil(since) and survivors != [] and high == [] -> "low_confidence_survivors"
        is_nil(since) and survivors != [] -> "unranked_survivors"
        since && sites == [] -> "no_mutable_changes"
        true -> "nothing_to_check"
      end

    killed = Map.get(counts, :killed, 0)
    survived = length(survivors)
    skipped = length(Map.get(mutation, :skipped, []))

    totals = %{
      "run" => length(results) + length(errors),
      "killed" => killed,
      "survived" => survived,
      "kill_rate" => kill_rate(killed, survived)
    }

    %{
      "verdict" => verdict,
      "checked" => checked(total + missing, unevaluated),
      "execution" => execution_counts(sites),
      "counts" => if(skipped > 0, do: Map.put(totals, "skipped", skipped), else: totals),
      "changed_functions" => if(since, do: changed_functions(groups, mutation)),
      "check_first" => Enum.map(check_first, &elem(&1, 1)),
      "worth_a_look" => Enum.map(ranked, &survivor_example(&1, report)),
      "worth_a_look_omitted" => length(worth) - length(ranked),
      "unevaluated" => unevaluated,
      "notes" =>
        notes(report, results, if(since, do: 0, else: length(low)), red, rejections) ++
          count_note("off_changed_line_survivors", length(away)) ++
          uncertain_functions(groups, report),
      "by_function" => by_function(groups, report),
      "source" => report.source
    }
  end

  defp execution_counts(sites) do
    counts = Enum.frequencies_by(sites, fn {_, site} -> site[:execution] end)
    Map.new([:cover, :probe, :could_not_tell], &{to_string(&1), Map.get(counts, &1, 0)})
  end

  defp uncertain_functions(groups, report) do
    functions =
      for {{_, function}, rows} <- groups,
          inconclusive?(rows),
          uniq: true,
          do: function

    case functions do
      [] ->
        []

      _ ->
        note = %{"kind" => "execution_could_not_tell", "count" => length(functions)}

        if report.source,
          do: [
            Map.put(note, "functions", functions |> Enum.sort() |> Enum.map(&Sanitizer.source/1))
          ],
          else: [note]
    end
  end

  defp inconclusive?(rows) do
    Enum.any?(rows, &match?({:could_not_tell, _}, &1)) and
      not Enum.any?(rows, fn {status, row} ->
        status != :uncovered and row[:execution] == :probe
      end)
  end

  defp checked(total, %{"count" => unchecked, "uncovered" => uncovered}) do
    %{
      "status" => if(unchecked > 0, do: "partial", else: "full"),
      "total" => total,
      "uncovered" => uncovered,
      "unevaluated" => unchecked - uncovered
    }
  end

  defp group_functions(sites) do
    sites
    |> Enum.filter(fn {_, site} -> is_binary(site[:function]) end)
    |> Enum.group_by(fn {_, site} -> function_key(site) end)
  end

  defp changed_functions(groups, mutation) do
    for(site <- Map.get(mutation, :skipped, []), site[:function], do: function_key(site))
    |> Enum.reduce(MapSet.new(Map.keys(groups)), &MapSet.put(&2, &1))
    |> MapSet.size()
  end

  defp check_first(groups, red_functions, report) do
    groups
    |> Enum.sort_by(fn {{file, function}, rows} -> {file, definition_line(rows), function} end)
    |> Enum.flat_map(fn {{_file, function} = key, rows} ->
      counts = Enum.frequencies_by(rows, &elem(&1, 0))
      uncovered = Map.get(counts, :uncovered, 0)
      survived = Map.get(counts, :survived, 0)

      examined =
        for {status, site} <- rows,
            status in [:killed, :survived],
            high?(site),
            not escalation_incomplete?(site),
            do: {status, site}

      cond do
        inconclusive?(rows) ->
          []

        Enum.all?(rows, &match?({:uncovered, %{execution: :probe}}, &1)) ->
          [finding(key, rows, "not_executed", survived, 0, rows, report)]

        length(examined) >= 3 and not Map.has_key?(counts, :killed) and
            not MapSet.member?(red_functions, function) ->
          [
            finding(
              key,
              rows,
              "nothing_asserted",
              survived,
              length(rows) - uncovered - Map.get(counts, :not_run, 0),
              examined,
              report
            )
          ]

        true ->
          []
      end
    end)
  end

  defp finding(key, rows, kind, survived, executed, candidates, report) do
    {_, site} = Enum.min_by(candidates, fn {_, site} -> rank(site) end)

    {key,
     key
     |> location(report)
     |> Map.merge(%{
       "kind" => kind,
       "line" => definition_line(rows),
       "counts" => %{"mutants" => length(rows), "survived" => survived, "executed" => executed},
       "example" => example(site, report)
     })}
  end

  defp function_key(site), do: {site.file, site[:function]}

  defp definition_line(rows) do
    Enum.min_by(rows, fn {_, site} -> site[:definition_line] || site.line end)
    |> elem(1)
    |> then(&(&1[:definition_line] || &1.line))
  end

  defp high?(site), do: Mutators.confidence(site.mutator) == :high

  defp escalation_incomplete?(site),
    do: get_in(site, [:selection, :escalation_incomplete]) == true

  defp rank(site),
    do: {
      escalation_incomplete?(site),
      Map.get(@precision, site.mutator, map_size(@precision)),
      site.file,
      site.line,
      site.id
    }

  defp changed_rank(site), do: {not high?(site), site.file, site.line, site.id}

  defp survivor_example(site, report) do
    example = example(site, report)
    if high?(site), do: example, else: Map.put(example, "confidence", "low")
  end

  defp example(site, report) do
    wire = JsonReporter.summary_site_to_wire(site, report)
    reference = Site.reference(site.id)
    steps = get_in(site, [:selection, :steps_run]) || default_steps(site)

    # A sanitized or source-free ID can't be used as a literal selector.
    id = if report.source, do: wire["id"], else: reference

    example =
      Map.merge(wire, %{
        "id" => id,
        "steps_run" => Enum.map(steps, &Atom.to_string/1),
        "rerun" => rerun(site, id, reference, report)
      })

    if escalation_incomplete?(site),
      do: Map.put(example, "escalation_incomplete", true),
      else: example
  end

  defp default_steps(%{status: _}), do: [:narrow]
  defp default_steps(_), do: []

  defp rerun(site, id, reference, report) do
    selector = if id == site.id and safe_literal?(id), do: id, else: reference
    options = report.rerun_options

    [
      "MIX_ENV=test mix mutagen",
      "--site",
      selector,
      "--tests",
      "auto",
      "--escalate",
      "--escalate-max-files",
      "40"
    ]
    |> append_since(get_in(report.meta || %{}, [:since, :base]))
    |> append_option("--seed", options[:seed], 0)
    |> append_option("--timeout-ms", options[:timeout_ms], nil)
    |> append_option("--boot-timeout-ms", options[:boot_timeout_ms], 300_000)
    |> append_flag("--no-host-app", options[:host_app] == false)
    |> append_flag("--no-test-alias", options[:test_alias] == false)
    |> append_flag("--no-fail-fast", options[:fail_fast] == false)
    |> append_flag("--no-source", not report.source)
    |> Enum.join(" ")
  end

  defp safe_literal?(id) do
    not String.starts_with?(id, "-") and
      Regex.match?(~r/\A[\w.\/:+-]+\z/, id) and Site.valid_selector?(id)
  end

  defp append_since(parts, base) when is_binary(base) do
    if Regex.match?(~r/\A(?:[a-f0-9]{40}|[a-f0-9]{64})\z/, base),
      do: parts ++ ["--since", base],
      else: parts
  end

  defp append_since(parts, _), do: parts

  defp append_option(parts, flag, value, default) when is_integer(value) and value != default,
    do: parts ++ [flag, Integer.to_string(value)]

  defp append_option(parts, _flag, _value, _default), do: parts

  defp append_flag(parts, flag, true), do: parts ++ [flag]
  defp append_flag(parts, _flag, false), do: parts

  defp location({file, function}, %{source: true}),
    do: %{"file" => Sanitizer.clean(file), "function" => Sanitizer.source(function)}

  defp location(_key, _report), do: %{}

  defp by_function(groups, report) do
    groups
    |> Enum.flat_map(fn {key, rows} ->
      counts = Enum.frequencies_by(rows, &elem(&1, 0))
      killed = Map.get(counts, :killed, 0)
      survived = Map.get(counts, :survived, 0)

      if killed + survived > 0 do
        [{kill_rate(killed, survived), key, killed, survived}]
      else
        []
      end
    end)
    |> Enum.sort()
    |> Enum.take(@function_cap)
    |> Enum.map(fn {rate, key, killed, survived} ->
      Map.merge(location(key, report), %{
        "mutants" => killed + survived,
        "killed" => killed,
        "survived" => survived,
        "kill_rate" => rate
      })
    end)
  end

  defp kill_rate(0, 0), do: nil
  defp kill_rate(killed, survived), do: killed / (killed + survived)

  defp unevaluated(counts) do
    counts =
      Map.new(~w(timeout error compile_error uncovered not_run could_not_tell)a, fn key ->
        {Atom.to_string(key), Map.get(counts, key, 0)}
      end)

    Map.put(counts, "count", Enum.sum(Map.values(counts)))
  end

  defp notes(report, results, low, red, rejections) do
    tainted = Enum.count(results, &(&1[:tainted_predecessors] == true))

    kills_after_drop =
      Enum.count(results, fn result ->
        result.status == :killed and get_in(result, [:selection, :after_dropped_file]) == true
      end)

    dropped_after_load =
      (report.meta || %{})
      |> Map.get(:escalation, [])
      |> Enum.sum_by(&Map.get(&1, :dropped_after_load, 0))

    rejected =
      for {reason, paths} <- Enum.sort(rejections),
          reason != :escalation_baseline_red,
          do: rejection(reason, paths, report)

    short_deadlines =
      for {:mutant_deadline_below_baseline, deadline_ms, baseline_ms} <-
            Enum.uniq(report.warnings) do
        %{
          "kind" => "mutant_deadline_below_baseline",
          "deadline_ms" => deadline_ms,
          "baseline_ms" => baseline_ms
        }
      end

    red_note(red, report) ++
      short_deadlines ++
      timeout_share(results, report.meta) ++
      count_note("tainted_predecessors", tainted) ++
      count_note("kills_after_dropped_file", kills_after_drop) ++
      count_note("escalation_dropped_after_load", dropped_after_load) ++
      escalation_times(report.meta) ++
      count_note("low_confidence_survivors", low) ++
      count_note("mutation_budget_exhausted", if(report.truncated, do: 1, else: 0)) ++
      rejected
  end

  defp timeout_share(results, %{timings_ms: %{mutation: wall_ms}}) when wall_ms > 0 do
    windows = for %{status: :timeout, timeout_window: window} <- results, do: window
    count = length(windows)
    wall = System.convert_time_unit(wall_ms, :millisecond, :native)

    if count >= 3 and timeout_wall_time(windows) * 2 > wall,
      do: count_note("mutation_timeouts_dominate", count),
      else: []
  end

  defp timeout_share(_results, _meta), do: []

  # Parallel mutation runs can spend the same time waiting on several sites.
  defp timeout_wall_time(windows) do
    [{first, last} | rest] = Enum.sort(windows)

    {_, total} =
      Enum.reduce(rest, {last, last - first}, fn {start, stop}, {last, total} ->
        {max(last, stop), total + max(0, stop - max(start, last))}
      end)

    total
  end

  defp escalation_times(%{timings_ms: %{total: total}, escalation: steps}) when total > 0 do
    measured = Enum.filter(steps, &is_integer(&1[:wall_ms]))

    if Enum.sum_by(measured, & &1.wall_ms) * 2 > total do
      for step <- measured do
        %{
          "kind" => "escalation_wall_time",
          "step" => to_string(step.step),
          "wall_ms" => step.wall_ms
        }
      end
    else
      []
    end
  end

  defp escalation_times(_meta), do: []

  defp count_note(_kind, 0), do: []
  defp count_note(kind, count), do: [%{"kind" => kind, "count" => count}]

  defp rejection(reason, paths, report) do
    paths = Enum.uniq(paths)

    note = %{
      "kind" => "escalation_dropped",
      "reason" => Atom.to_string(reason),
      "count" => length(paths)
    }

    if report.source,
      do: Map.put(note, "files", Enum.map(paths, &Sanitizer.clean/1)),
      else: note
  end

  defp rejected_files(warnings) do
    files =
      for {:escalation_rejected, reason, paths} <- warnings, path <- paths, do: {reason, path}

    Enum.group_by(files, &elem(&1, 0), &elem(&1, 1))
  end

  defp red_note([], _report), do: []

  defp red_note(paths, report) do
    [rejection(:baseline_red, paths, report) |> Map.put("kind", "baseline_red_files")]
  end
end
