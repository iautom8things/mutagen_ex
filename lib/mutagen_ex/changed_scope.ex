defmodule MutagenEx.ChangedScope do
  @moduledoc false

  alias MutagenEx.{AstCache, GitDiff, MutationEnumerator, ScopeResolver}

  def plan(config, roots) do
    opts = [roots: roots, deletion_anchors: true, allow_missing_roots: true]

    with {:ok, diff} <- GitDiff.changed_lines(config.since, opts) do
      files =
        (Map.keys(diff.files) ++ Map.keys(diff.deletion_anchors) ++ Map.keys(diff.renames))
        |> Enum.uniq()
        |> Enum.sort()

      {cache, incomplete} = load_files(files, diff.skipped)

      meta = %{
        ref: config.since,
        base: diff.base,
        changed_files: length(files),
        planned: 0,
        in_scope: 0,
        runtime: 0,
        run: 0
      }

      plan = %{meta: meta, incomplete: incomplete, warnings: diff.warnings, head: diff.head}

      with {:ok, scopes} <- resolve_scopes(config.scopes, cache, files, roots) do
        plan = enumerate(plan, diff, scopes, cache, files, config, opts)
        {:ok, plan}
      else
        {:error, reason, details} -> {:error, reason, details, plan}
      end
    end
  end

  def changed_tests(plan, roots) do
    opts = [roots: roots, file_kind: :test, allow_missing_roots: true]

    case GitDiff.changed_lines(plan.meta.ref, opts) do
      {:ok, %{base: base, head: head} = diff} when base == plan.meta.base and head == plan.head ->
        {:ok, Enum.sort(Map.keys(diff.files)), diff.skipped}

      {:ok, _diff} ->
        {:error, :diff_unavailable, %{cause: :history_changed}}

      {:error, _, _} = error ->
        error
    end
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

  defp enumerate(plan, diff, scopes, cache, files, config, opts) do
    lines =
      Map.new(cache, fn {file, {_ast, source}} ->
        {file, Map.get(diff.files, file, []) ++ anchor_ranges(diff, file, source)}
      end)

    enumerated =
      MutationEnumerator.enumerate(cache, scopes, %{}, planned: lines, source: config.source)

    planned = enumerated.sites ++ enumerated.skipped
    planned_by_file = Enum.group_by(planned, & &1.file)

    {entries, incomplete} =
      Enum.map_reduce(files, plan.incomplete, fn file, incomplete ->
        entries = Map.get(planned_by_file, file, [])
        base_path = Map.get(diff.renames, file, file)

        {scoped, reasons} =
          case GitDiff.base_file(diff.base, base_path, opts) do
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

        {annotate(scoped, reason), incomplete}
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
        | planned: length(planned),
          in_scope: length(entries),
          runtime: length(sites) + length(skipped)
      }
    })
  end

  defp annotate(entries, reason) do
    {annotated, _groups} =
      Enum.map_reduce(entries, %{}, fn %{group_key: key} = entry, groups ->
        digest = Map.get_lazy(groups, key, fn -> MutationEnumerator.site_fingerprint(entry) end)

        {Map.merge(entry, %{in_scope: reason, fingerprint: digest}),
         Map.put_new(groups, key, digest)}
      end)

    annotated
  end

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
