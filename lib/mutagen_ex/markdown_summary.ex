defmodule MutagenEx.MarkdownSummary do
  @moduledoc false

  @headlines %{
    "nothing_to_check" => "Mutagen found nothing to check",
    "check_first" => "Mutagen found functions to check first",
    "worth_a_look" => "Mutagen found changes worth a look",
    "incomplete" => "Mutagen has incomplete results",
    "no_mutable_changes" => "Mutagen found no mutable changes"
  }

  @findings %{
    "not_executed" => "Selected tests executed none of the in-scope sites",
    "nothing_asserted" => "All evaluated high-confidence mutants survived"
  }

  @incomplete %{
    "ast_cache_miss" => "Missing cached source",
    "base_parse_error" => "Could not parse the base source",
    "base_read_failed" => "Could not read the base source",
    "binary" => "Skipped a binary file",
    "current_parse_error" => "Could not parse the current source",
    "current_read_failed" => "Could not read the current source",
    "gitlink" => "Skipped a Git link",
    "site_node_not_found" => "Could not find a planned site in the source",
    "symlink" => "Skipped a symlink",
    "type_change" => "Skipped a file that changed type",
    "unsupported_mode" => "Skipped an unsupported file type"
  }

  @rejections %{
    "escalation_baseline_red" => "tests failed on original code",
    "escalation_baseline_red_in_combination" => "tests failed when run together",
    "escalation_baseline_timeout" => "tests timed out on original code",
    "escalation_test_file_load_failed" => "test files failed to load",
    "escalation_test_read_failed" => "test files could not be read",
    "escalation_no_tests_run" => "no tests ran",
    "escalation_baseline_crashed" => "tests crashed on original code"
  }

  @spec render(map()) :: iodata()
  def render(%{"summary" => summary} = report) do
    meta = report["meta"] || %{}
    notes = notes(meta, summary)

    [
      headline(summary, meta["since"]),
      section("Check first", summary["check_first"], &finding/1),
      section("Worth a look", summary["worth_a_look"], &mutant/1),
      omitted(summary["worth_a_look_omitted"]),
      meaning_separator(summary),
      "**What this means.** A survivor means the tests that ran did not notice the change. Check what they assert.\n",
      if(notes == [], do: [], else: ["\n### Notes\n\n", notes])
    ]
  end

  defp headline(summary, since) do
    counts = summary["counts"]

    changed =
      if since,
        do: [
          " · ",
          quantity(since["changed_files"] || 0, "changed file"),
          " · ",
          quantity(summary["changed_functions"], "changed function")
        ],
        else: ""

    [
      "**",
      Map.fetch!(@headlines, summary["verdict"]),
      ".** ",
      "#{quantity(counts["run"], "mutant")} run · #{counts["killed"]} killed · #{counts["survived"]} survived",
      " · #{summary["unevaluated"]["count"]} unevaluated · kill rate #{percent(counts["kill_rate"])}",
      changed,
      "\n"
    ]
  end

  defp quantity(1, unit), do: "1 #{unit}"
  defp quantity(count, unit), do: "#{count} #{unit}s"

  defp percent(nil), do: "n/a"
  defp percent(rate), do: "#{Float.round(rate * 100, 1)}%"

  defp section(_title, [], _renderer), do: []

  defp section(title, entries, renderer),
    do: ["\n### ", title, "\n\n", Enum.intersperse(Enum.map(entries, renderer), "\n")]

  defp finding(%{"counts" => counts, "example" => example} = entry) do
    [
      "- ",
      location(entry),
      " ",
      Map.fetch!(@findings, entry["kind"]),
      " (#{quantity(counts["mutants"], "mutant")}, #{counts["survived"]} survived, #{counts["executed"]} executed).\n",
      details(example)
    ]
  end

  defp mutant(entry) do
    steps = Enum.join(entry["steps_run"], ", ")

    [
      "- ",
      location(entry),
      " ",
      inline(entry["mutator"]),
      " survived (#{steps}).\n",
      details(entry)
    ]
  end

  defp location(%{"file" => file, "function" => function, "line" => line})
       when is_binary(function),
       do: [inline("#{file}:#{line}"), " ", inline(function), "."]

  defp location(%{"file" => file, "line" => line}), do: [inline("#{file}:#{line}"), "."]
  defp location(%{"line" => line}), do: "Line #{line}."

  defp details(entry) do
    [diff(entry), "  Rerun with ", inline(entry["rerun"]), ".\n"]
  end

  defp diff(%{"before_source" => before, "after" => after_source})
       when is_binary(before) and is_binary(after_source) do
    ["\n  ```diff\n", diff_lines(before, "-"), diff_lines(after_source, "+"), "  ```\n\n"]
  end

  defp diff(_), do: []

  defp diff_lines(text, prefix) do
    {lines, rest} = text |> String.split("\n") |> Enum.split(8)

    [
      Enum.map(lines, &["  ", prefix, " ", String.slice(&1, 0, 160), "\n"]),
      if(rest == [], do: [], else: ["  ", prefix, " …\n"])
    ]
  end

  defp omitted(0), do: []

  defp omitted(count),
    do: ["\n#{quantity(count, "additional high-confidence survivor")} in the JSON.\n"]

  defp meaning_separator(summary) do
    if no_findings?(summary) and summary["worth_a_look_omitted"] == 0, do: [], else: "\n"
  end

  defp no_findings?(summary), do: summary["check_first"] == [] and summary["worth_a_look"] == []

  defp notes(meta, summary) do
    incomplete =
      for row <- meta["incomplete_reasons"] || [] do
        message = Map.get(@incomplete, row["reason"], "Some inputs could not be checked")
        ["- ", message, path(row["path"]), ".\n"]
      end

    unmapped =
      for row <- get_in(meta, ["since", "unmapped"]) || [] do
        ranges = Enum.map_join(row["ranges"], ", ", &range/1)

        [
          "- Changed lines outside runtime mutation sites",
          path(row["path"]),
          " (",
          ranges,
          ").\n"
        ]
      end

    source =
      if summary["source"] or (incomplete == [] and unmapped == [] and no_findings?(summary)) do
        []
      else
        ["- File names, function names and excerpts omitted by `--no-source`.\n"]
      end

    timeouts =
      case summary["unevaluated"]["timeout"] do
        0 -> []
        count -> ["- #{quantity(count, "mutant")} timed out.\n"]
      end

    incomplete ++ unmapped ++ timeouts ++ Enum.map(summary["notes"], &note/1) ++ source
  end

  defp range([line, line]), do: Integer.to_string(line)
  defp range([first, last]), do: "#{first}–#{last}"

  defp note(%{"kind" => "escalation_dropped", "count" => count, "reason" => reason} = note) do
    files = Enum.map_intersperse(note["files"] || [], ", ", &inline/1)

    [
      "- Skipped #{quantity(count, "test file")} during escalation (",
      Map.get(@rejections, reason, "could not admit tests"),
      ")",
      if(files == [], do: [], else: [" in ", files]),
      ".\n"
    ]
  end

  defp note(%{"kind" => "tainted_predecessors", "count" => count}),
    do: "- #{quantity(count, "result")} followed a timeout or host state change.\n"

  defp note(%{"kind" => "kills_after_dropped_file", "count" => count}),
    do:
      "- #{quantity(count, "kill")} followed a dropped test file and may reflect its effects on the run.\n"

  defp note(%{"kind" => "escalation_dropped_after_load", "count" => count}),
    do: "- Escalation tried to load #{quantity(count, "test file")} that it later dropped.\n"

  defp note(%{"kind" => "low_confidence_survivors", "count" => count}),
    do: "- Only the JSON results list #{quantity(count, "low-confidence survivor")}.\n"

  defp note(%{"kind" => "mutation_budget_exhausted"}),
    do: "- The mutation time budget expired before the run finished.\n"

  defp note(%{"kind" => "escalation_failed"}),
    do: "- Escalation stopped early. The JSON retains the narrow results.\n"

  defp path(nil), do: []
  defp path(file), do: [" in ", inline(file)]

  defp inline(text) do
    text = String.replace(text, ["\n", "\r"], " ")

    longest =
      ~r/`+/
      |> Regex.scan(text)
      |> Enum.map(fn [run] -> byte_size(run) end)
      |> Enum.max(fn -> 0 end)

    fence = String.duplicate("`", longest + 1)

    if longest == 0, do: [fence, text, fence], else: [fence, " ", text, " ", fence]
  end
end
