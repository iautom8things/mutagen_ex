defmodule MutagenEx.ChangedScope do
  @moduledoc false

  alias MutagenEx.{AstCache, GitDiff, MutationEnumerator, ScopeResolver}

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
        unmapped: []
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
        {:ok, Enum.sort(Map.keys(diff.files)), diff.skipped}

      {:ok, _diff} ->
        {:error, :diff_unavailable, %{cause: :history_changed}}

      {:error, _, _} = error ->
        error
    end
  end

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
              {stat.inode, stat.major_device, stat.minor_device} ==
                {other.inode, other.major_device, other.minor_device}

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
    {sites, skipped} = Enum.split_with(Enum.filter(entries, & &1.runtime?), &is_map_key(&1, :id))

    Map.merge(plan, %{
      scopes: scopes,
      cache: cache,
      sites: sites,
      skipped: skipped,
      incomplete: incomplete,
      meta: %{
        plan.meta
        | planned: Enum.sum_by(planned_by_file, fn {_, entries} -> length(entries) end),
          in_scope: length(entries),
          runtime: length(sites) + length(skipped),
          unmapped: unmapped(lines, diff, planned_by_file)
      }
    })
  end

  defp planned_span(index, entry) do
    MutagenEx.JsonReporter.Source.line_range(index, entry.path) ||
      {entry.line, entry.end_line || entry.line}
  end

  defp overlaps?({first, last}, ranges),
    do: Enum.any?(ranges, fn {from, to} -> first <= to and from <= last end)

  defp unmapped(lines, diff, planned_by_file) do
    Enum.flat_map(Enum.sort(lines), fn {path, changed} ->
      spans = for {%{runtime?: true}, span} <- Map.get(planned_by_file, path, []), do: span
      ranges = Enum.reduce(spans, changed, &subtract_span/2) |> Enum.uniq() |> Enum.sort()
      anchors = Map.get(diff.deletion_anchors, path, [])

      unmapped =
        if ranges == [],
          do: [],
          else: [%{path: path, ranges: wire_ranges(ranges), kind: :no_runtime_site}]

      if changed == [] and anchors != [] do
        [
          %{
            path: path,
            ranges: wire_ranges(Enum.map(anchors, &{&1, &1})),
            kind: :deletion_without_neighbor
          }
        ]
      else
        unmapped
      end
    end)
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
