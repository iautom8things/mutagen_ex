defmodule MutagenEx.ChangedScope do
  @moduledoc false

  alias MutagenEx.{AstCache, FileIdentity, GitDiff, MutationEnumerator, Mutators, ScopeResolver}

  def plan(config, roots, options \\ []) do
    opts = [roots: roots, deletion_anchors: true, untracked: true]
    git = Keyword.get(options, :git, GitDiff)
    excluded = Keyword.get(options, :exclude, [])

    with {:ok, diff} <- git.changed_lines(config.since, opts) do
      files =
        (Map.keys(diff.files) ++ Map.keys(diff.deletion_anchors) ++ Map.keys(diff.renames))
        |> Enum.uniq()
        |> Enum.reject(&excluded?(&1, excluded))
        |> Enum.sort()

      skipped = Enum.reject(diff.skipped, &excluded?(&1.path, excluded))
      {cache, incomplete} = load_files(files, skipped)

      meta = %{
        ref: config.since,
        base: diff.base,
        changed_files: length(files),
        planned: 0,
        in_scope: 0,
        runtime: 0,
        run: 0,
        unmapped: [],
        out_of_scope: [],
        uncovered: []
      }

      plan = %{meta: meta, incomplete: incomplete, warnings: diff.warnings, head: diff.head}

      with {:ok, scopes} <- resolve_scopes(config.scopes, cache, files, roots) do
        plan = enumerate(plan, diff, scopes, cache, files, config, {git, opts})
        {:ok, plan}
      else
        {:error, reason, details} -> {:error, reason, details, plan}
      end
    end
  end

  def changed_tests(plan, roots, git \\ GitDiff) do
    opts = [roots: roots, file_kind: :test, allow_missing_roots: true, untracked: true]

    case git.changed_lines(plan.meta.ref, opts) do
      {:ok, %{base: base, head: head} = diff} when base == plan.meta.base and head == plan.head ->
        changed =
          diff.files
          |> Map.keys()
          |> Enum.sort()
          |> Enum.reject(fn path ->
            old_path = Map.get(diff.renames, path, path)
            unchanged_test?(path, git.base_file(base, old_path, opts))
          end)

        {:ok, changed, diff.skipped}

      {:ok, _diff} ->
        {:error, :diff_unavailable, %{cause: :history_changed}}

      {:error, _, _} = error ->
        error
    end
  end

  defp unchanged_test?(path, {:ok, previous}) do
    with {:ok, current} <- File.read(path),
         {:ok, before_ast} <- Code.string_to_quoted(previous, emit_warnings: false),
         {:ok, after_ast} <- Code.string_to_quoted(current, emit_warnings: false) do
      Mutators.identity_node(before_ast) == Mutators.identity_node(after_ast)
    else
      _ -> false
    end
  rescue
    UnicodeConversionError -> false
  end

  defp unchanged_test?(_path, _previous), do: false

  def excluded?(path, roots) do
    path = String.normalize(path, :nfc)

    Enum.any?(roots, fn root ->
      root = String.normalize(root, :nfc)
      path == root or String.starts_with?(path, root <> "/")
    end)
  end

  defp load_files(files, skipped) do
    {cache, incomplete} =
      Enum.reduce(files, {%{}, []}, fn file, {cache, incomplete} ->
        case load_file(file) do
          {:ok, parsed} -> {Map.merge(cache, parsed), incomplete}
          {:error, reason} -> {cache, [%{path: file, reason: reason} | incomplete]}
        end
      end)

    {cache, Enum.reverse(incomplete, skipped)}
  end

  defp load_file(file) do
    case AstCache.load([file]) do
      {:ok, parsed} -> {:ok, parsed}
      {:error, :file_read_failed, _} -> {:error, :current_read_failed}
      {:error, :parse_error, _} -> {:error, :current_parse_error}
    end
  rescue
    UnicodeConversionError -> {:error, :current_parse_error}
  end

  defp resolve_scopes([], cache, files, _roots) do
    {:ok,
     for file <- files,
         {ast, _} <- List.wrap(cache[file]),
         scope <- ScopeResolver.file_scopes(file, ast) do
       scope
     end}
  end

  defp resolve_scopes(_targets, _cache, [], _roots), do: {:ok, []}

  defp resolve_scopes(targets, cache, files, roots) do
    invalid_files = files -- Map.keys(cache)

    source_files =
      (files ++ Enum.flat_map(roots, &Path.wildcard(Path.join(&1, "**/*.ex"))))
      |> Enum.uniq()
      |> Kernel.--(invalid_files)

    Enum.reduce_while(targets, {:ok, []}, fn target, {:ok, chunks} ->
      case resolve_target(target, cache, files, source_files) do
        {:ok, records} -> {:cont, {:ok, [records | chunks]}}
        {:error, _, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, chunks} -> {:ok, chunks |> Enum.reverse() |> List.flatten()}
      error -> error
    end
  end

  defp resolve_target(target, cache, files, source_files) do
    if String.ends_with?(target, ".ex") and not String.contains?(target, ":") do
      path = Path.relative_to(Path.expand(target), File.cwd!(), force: true)

      case find_git_path(path, files) do
        nil -> {:ok, []}
        file -> resolve_scopes([], cache, [file], [])
      end
    else
      case ScopeResolver.resolve(target, source_files: source_files) do
        {:ok, records} -> {:ok, Enum.filter(records, &Map.has_key?(cache, &1.file))}
        {:error, _, _} = error -> error
      end
    end
  end

  defp find_git_path(path, files) do
    if path in files do
      path
    else
      # A caller can spell a path differently on a case-insensitive filesystem.
      with {:ok, stat} <- File.stat(path) do
        Enum.find(files, fn file ->
          case File.stat(file) do
            {:ok, other} ->
              FileIdentity.key(stat) == FileIdentity.key(other)

            _ ->
              false
          end
        end)
      else
        _ -> nil
      end
    end
  end

  defp enumerate(plan, diff, scopes, cache, files, config, {git, opts}) do
    lines =
      Map.new(cache, fn {file, {_ast, source}} ->
        {file, Map.get(diff.files, file, []) ++ anchor_ranges(diff, file, source)}
      end)

    enumerated =
      MutationEnumerator.enumerate(cache, scopes, %{}, planned: lines, source: config.source)

    planned_by_file =
      (enumerated.sites ++ enumerated.skipped)
      |> Enum.group_by(& &1.file)
      |> Map.new(fn {path, entries} ->
        {_ast, source} = Map.fetch!(cache, path)
        index = MutagenEx.JsonReporter.Source.index(source, path)

        entries =
          for entry <- entries,
              span = planned_span(index, entry),
              overlaps?(span, lines[path]) do
            {entry, span}
          end

        {path, entries}
      end)

    {entries, incomplete} =
      Enum.map_reduce(files, plan.incomplete, fn file, incomplete ->
        entries = Enum.map(Map.get(planned_by_file, file, []), &elem(&1, 0))
        base_path = Map.get(diff.renames, file, file)

        {scoped, reasons} =
          case git.base_file(diff.base, base_path, opts) do
            {:ok, source} ->
              {scoped, warnings} = MutationEnumerator.fingerprint_scope(entries, source)
              reason = if warnings == [], do: :changed_group, else: :base_parse_error
              {scoped, {reason, warnings != []}}

            :absent ->
              {entries, {:new_file, false}}

            {:error, _, _} ->
              {entries, {:base_read_failed, true}}
          end

        {reason, incomplete?} = reasons

        incomplete =
          if incomplete?, do: [%{reason: reason, path: file} | incomplete], else: incomplete

        {Enum.map(scoped, &Map.put(&1, :in_scope, reason)), incomplete}
      end)

    entries = List.flatten(entries)
    {changed, out_of_scope} = scope_lines(diff.files, scopes, config.scopes)
    {sites, skipped} = Enum.split_with(Enum.filter(entries, & &1.runtime?), &is_map_key(&1, :id))

    Map.merge(plan, %{
      scopes: scopes,
      cache: cache,
      sites: sites,
      skipped: skipped,
      changed_lines: changed,
      multi_line_sites: multi_line_sites(planned_by_file, sites),
      incomplete: incomplete,
      meta: %{
        plan.meta
        | planned: Enum.sum_by(planned_by_file, fn {_, entries} -> length(entries) end),
          in_scope: length(entries),
          runtime: length(sites) + length(skipped),
          unmapped:
            unmapped(changed, planned_by_file, entries, cache) ++ empty_file_anchors(lines, diff),
          out_of_scope: out_of_scope
      }
    })
  end

  defp planned_span(index, entry) do
    MutagenEx.JsonReporter.Source.line_range(index, entry.path) ||
      {entry.line, entry.end_line || entry.line}
  end

  defp overlaps?({first, last}, ranges),
    do: Enum.any?(ranges, fn {from, to} -> first <= to and from <= last end)

  defp scope_lines(files, _scopes, []), do: {files, []}

  defp scope_lines(files, scopes, _targets) do
    by_file = Enum.group_by(scopes, & &1.file, &{&1.line_range.first, &1.line_range.last})

    Enum.sort(files)
    |> Enum.reduce({%{}, []}, fn {path, changed}, {inside, outside} ->
      spans = Map.get(by_file, path, [])
      excluded = Enum.reduce(spans, changed, &subtract_span/2)
      included = Enum.reduce(excluded, changed, &subtract_span/2)
      outside = if excluded == [], do: outside, else: [row(path, excluded) | outside]
      {Map.put(inside, path, included), outside}
    end)
    |> then(fn {inside, outside} -> {inside, Enum.reverse(outside)} end)
  end

  defp unmapped(changed, planned, entries, cache) do
    new_clauses =
      for %{runtime?: true, clause_range: {first, last}} = entry <- entries,
          new_group?(entry) or
            Enum.any?(changed[entry.file] || [], fn {from, to} ->
              from <= first and last <= to
            end),
          do: {entry.file, entry.clause_range}

    new_clauses = Enum.group_by(new_clauses, &elem(&1, 0), &elem(&1, 1))

    for {path, lines} <- Enum.sort(changed),
        {_ast, source} <- List.wrap(cache[path]),
        spans = for({%{runtime?: true}, span} <- Map.get(planned, path, []), do: span),
        spans = spans ++ Map.get(new_clauses, path, []),
        ranges = spans |> Enum.reduce(lines, &subtract_span/2) |> then(&code_ranges(source, &1)),
        ranges != [] do
      Map.put(row(path, ranges), :kind, :no_runtime_site)
    end
  end

  # Groups absent from the base still carry their deferred fingerprint.
  defp new_group?(entry), do: is_tuple(entry.fingerprint)

  defp empty_file_anchors(lines, diff) do
    for {path, []} <- Enum.sort(lines),
        anchors = Map.get(diff.deletion_anchors, path, []),
        anchors != [] do
      Map.put(row(path, Enum.map(anchors, &{&1, &1})), :kind, :deletion_without_neighbor)
    end
  end

  defp multi_line_sites(planned, sites) do
    ids = MapSet.new(sites, & &1.id)

    for {path, pairs} <- planned, into: %{} do
      spans =
        for {%{id: id}, {first, last}} <- pairs,
            first < last and MapSet.member?(ids, id),
            do: {id, {first + 1, last}}

      {path, spans}
    end
  end

  def uncovered_lines(plan, coverage, evaluated, pending) do
    uncovered = MapSet.new(for %{id: id, reason: :uncovered} <- pending, do: id)

    spans_by_file =
      for %{file: file, id: id, coverage_location: {_, {first, last}, _, _}} <- plan.sites,
          MapSet.member?(uncovered, id),
          do: {file, {first, last}}

    spans_by_file = Enum.group_by(spans_by_file, &elem(&1, 0), &elem(&1, 1))

    for {path, lines} <- Enum.sort(plan.changed_lines),
        spans = Map.get(plan.multi_line_sites, path, []),
        spans != [],
        {_ast, source} <- List.wrap(plan.cache[path]),
        hit = Map.get(coverage.covered_lines, path, MapSet.new()),
        measured = Map.get(coverage.coverable_lines, path, MapSet.new()),
        uncovered_spans = Map.get(spans_by_file, path, []),
        ranges = evaluated_ranges(lines, spans, evaluated),
        ranges =
          code_ranges(source, ranges, fn line ->
            not MapSet.member?(hit, line) and
              (MapSet.member?(measured, line) or overlaps?({line, line}, uncovered_spans))
          end),
        ranges != [] do
      row(path, ranges)
    end
  end

  defp evaluated_ranges(lines, spans, evaluated) do
    for {id, {first, last}} <- spans,
        MapSet.member?(evaluated, id),
        {from, to} <- lines,
        low = max(first, from),
        high = min(last, to),
        low <= high,
        do: {low, high}
  end

  defp row(path, ranges), do: %{path: path, ranges: wire_ranges(ranges)}

  defp code_ranges(source, ranges, select? \\ fn _ -> true end)
  defp code_ranges(_source, [], _covered), do: []

  defp code_ranges(source, ranges, select?) do
    {_, code} =
      source
      |> String.splitter("\n")
      |> Stream.with_index(1)
      |> Enum.reduce_while({Enum.sort(ranges), []}, fn {text, line}, {ranges, code} ->
        case Enum.drop_while(ranges, fn {_, last} -> last < line end) do
          [] ->
            {:halt, {[], code}}

          [{first, _} | _] = ranges ->
            code =
              if line >= first and select?.(line) and
                   code_line?(String.trim(text)),
                 do: add_line(code, line),
                 else: code

            {:cont, {ranges, code}}
        end
      end)

    Enum.reverse(code)
  end

  defp add_line([{first, last} | rest], line) when last == line - 1, do: [{first, line} | rest]
  defp add_line(ranges, line), do: [{line, line} | ranges]

  defp code_line?(""), do: false
  defp code_line?("#" <> _), do: false

  defp code_line?(text) do
    not Regex.match?(
      ~r/^(?:(?:end|do|else|rescue|catch|after)|[\])},]+|defmodule\s+[^,;#]+\s+do)\s*(#.*)?$/u,
      text
    )
  end

  defp subtract_span({first, last}, ranges) do
    Enum.flat_map(ranges, fn
      {from, to} when to < first or from > last -> [{from, to}]
      {from, to} -> Enum.filter([{from, first - 1}, {last + 1, to}], fn {a, b} -> a <= b end)
    end)
  end

  defp wire_ranges(ranges), do: Enum.map(ranges, &Tuple.to_list/1)

  defp anchor_ranges(diff, file, source) do
    case Map.get(diff.deletion_anchors, file, []) do
      [] ->
        []

      anchors ->
        last = line_count(source)

        for anchor <- anchors, from = max(anchor, 1), to = min(anchor + 1, last), from <= to do
          {from, to}
        end
    end
  end

  defp line_count(""), do: 0

  defp line_count(source) do
    length(:binary.matches(source, "\n")) + if(:binary.last(source) == ?\n, do: 0, else: 1)
  end
end
