defmodule MutagenEx.AutoTests do
  @moduledoc false

  alias MutagenEx.FileIdentity

  def select(scopes, source_roots, test_roots, changed) do
    convention =
      for file <- Enum.uniq_by(scopes, & &1.file),
          root <- source_roots,
          {:ok, relative} <- [relative_source(file.file, root)],
          test_root <- test_roots,
          path = Path.join(test_root, Path.rootname(relative) <> "_test.exs"),
          regular_path?(path) do
        %{path: path, why: :convention}
      end

    changed
    |> Enum.map(&%{path: &1, why: :changed_in_diff})
    |> Kernel.++(convention)
    |> Enum.uniq_by(&file_identity(&1.path))
    |> Enum.sort_by(& &1.path)
  end

  def discover(stage, sites, paths, tried, cap, reader \\ &File.read/1) do
    case patterns(stage, sites) do
      [] -> {[], false, []}
      patterns -> rank_files(paths, tried, cap, patterns, reader)
    end
  end

  def mentioned_functions([], _sites), do: MapSet.new()

  def mentioned_functions(paths, sites) do
    patterns = patterns(:function, sites)

    for path <- paths,
        {:ok, source} <- [File.read(path)],
        {{module, name, arity}, pattern} <- patterns,
        count_matches(pattern, source) > 0,
        into: MapSet.new() do
      "#{module}.#{name}/#{arity}"
    end
  end

  defp rank_files(paths, tried, cap, patterns, reader) do
    tried = MapSet.new(tried, &file_identity/1)

    {scores, unreadable} =
      paths
      |> Enum.flat_map(&Path.wildcard(Path.join(&1, "**/*_test.exs")))
      |> Enum.sort()
      |> Enum.filter(&regular_path?/1)
      |> Enum.uniq_by(&file_identity/1)
      |> Enum.reject(&MapSet.member?(tried, file_identity(&1)))
      |> Enum.reduce({%{}, []}, fn path, {scores, unreadable} ->
        case reader.(path) do
          {:ok, source} ->
            scores =
              Enum.reduce(patterns, scores, fn {group, pattern}, scores ->
                case count_matches(pattern, source) do
                  0 -> scores
                  score -> Map.update(scores, group, [{path, score}], &[{path, score} | &1])
                end
              end)

            {scores, unreadable}

          {:error, _} ->
            {scores, [path | unreadable]}
        end
      end)

    {union, capped?} =
      Enum.reduce(scores, {%{}, false}, fn {_group, files}, {union, capped?} ->
        chosen = files |> rank() |> Enum.take(cap)

        union =
          Enum.reduce(chosen, union, fn {path, score}, acc ->
            Map.update(acc, path, score, &(&1 + score))
          end)

        {union, capped? or length(files) > cap}
      end)

    {Enum.map(rank(union), &elem(&1, 0)), capped?, Enum.reverse(unreadable)}
  end

  defp rank(files), do: Enum.sort_by(files, fn {path, score} -> {-score, path} end)

  defp file_identity(path) do
    case File.lstat(path) do
      {:ok, %{type: :regular} = stat} ->
        FileIdentity.key(stat)

      _ ->
        path
    end
  end

  defp relative_source(file, root) do
    relative = Path.relative_to(file, root)

    cond do
      relative != file ->
        {:ok, relative}

      String.starts_with?(String.normalize(file, :nfc), String.normalize(root, :nfc) <> "/") ->
        {:ok, file |> Path.split() |> Enum.drop(length(Path.split(root))) |> Path.join()}

      true ->
        relative_case_folded(file, root)
    end
  end

  defp relative_case_folded(file, root) do
    {prefix, relative} = Enum.split(Path.split(file), length(Path.split(root)))

    with [_ | _] <- relative,
         true <- String.downcase(Path.join(prefix)) == String.downcase(root),
         true <- FileIdentity.same?(root, Path.join(prefix)) do
      {:ok, Path.join(relative)}
    else
      _ -> :error
    end
  end

  # Traverse without following symlinks. Discovery must stay under the test roots.
  defp regular_path?(path) do
    Path.split(path)
    |> Enum.reduce_while("", fn part, parent ->
      entry = Path.join(parent, part)

      case File.lstat(entry) do
        {:ok, %{type: :directory}} -> {:cont, entry}
        {:ok, %{type: :regular}} -> {:halt, entry == path}
        _ -> {:halt, false}
      end
    end) == true
  end

  defp patterns(stage, sites) do
    sites
    |> Enum.flat_map(fn
      %{function: mfa} when is_binary(mfa) ->
        case Regex.run(~r/\A(.+)\.([^.]+)\/([0-9]+)\z/, mfa, capture: :all_but_first) do
          [module, name, arity] -> [{module, name, arity}]
          nil -> []
        end

      _ ->
        []
    end)
    |> Enum.uniq()
    |> Enum.map(fn {module, name, arity} = group ->
      {parent, last} = module_parts(module)
      full = "(?:Elixir\\.)?" <> Regex.escape(module)
      last = Regex.escape(last)
      {group, pattern(stage, full, parent, last, Regex.escape(name), arity)}
    end)
  end

  defp pattern(:module, full, parent, last, _, _) do
    parent_alias =
      if parent != "",
        do:
          Regex.compile!(
            "\\balias\\s+(?:Elixir\\.)?" <> Regex.escape(parent) <> "(?![A-Za-z0-9_.])"
          )

    {:module, Regex.compile!(boundary(full)), parent_alias, Regex.compile!(whole_word(last))}
  end

  defp pattern(:function, full, parent, last, name, arity) do
    imported = Regex.compile!("\\b(?:import|alias)\\s+" <> full <> "(?![A-Za-z0-9_.])")
    local = call_pattern("", name, arity)
    short = call_pattern(last <> "\\.", name, arity)
    qualified = call_pattern(full <> "\\.", name, arity)

    named_alias =
      Regex.compile!("\\balias\\s+" <> full <> "\\s*,\\s*as:\\s*([A-Z][A-Za-z0-9_]*)")

    # A literal Module.concat assignment also gives a statically named receiver.
    computed_alias =
      if parent != "" do
        Regex.compile!(
          "\\b([a-z_][A-Za-z0-9_]*)\\s*=\\s*Module\\.concat\\(\\s*" <>
            Regex.escape(parent) <> "\\s*,\\s*" <> last <> "\\s*\\)"
        )
      end

    {:function, short, qualified, imported, local, named_alias, computed_alias, name, arity}
  end

  defp call_pattern(receiver, name, arity) do
    head = receiver <> name

    Regex.compile!(
      boundary(head) <> "\\s*\\(|&\\s*" <> head <> "\\s*/\\s*" <> arity <> "(?![0-9])"
    )
  end

  defp boundary(text), do: "(?<![A-Za-z0-9_.])" <> text <> "(?![A-Za-z0-9_])"
  defp whole_word(text), do: "(?<![A-Za-z0-9_])" <> text <> "(?![A-Za-z0-9_])"

  defp module_parts(module) do
    [last | parent] = module |> String.split(".") |> Enum.reverse()
    {Enum.join(Enum.reverse(parent), "."), last}
  end

  defp count_matches({:module, full, parent_alias, last}, source) do
    case Regex.scan(full, source) do
      [] ->
        if parent_alias && Regex.match?(parent_alias, source), do: count(last, source), else: 0

      matches ->
        length(matches)
    end
  end

  defp count_matches(
         {:function, short, qualified, imported, local, named, computed, name, arity},
         source
       ) do
    aliases =
      for regex <- [named, computed],
          regex != nil,
          [alias_name] <- Regex.scan(regex, source, capture: :all_but_first),
          uniq: true do
        call_pattern(Regex.escape(alias_name) <> "\\.", name, arity)
      end

    patterns = [short, qualified | aliases]
    patterns = if Regex.match?(imported, source), do: [local | patterns], else: patterns
    Enum.sum_by(patterns, &count(&1, source))
  end

  defp count(pattern, source), do: length(Regex.scan(pattern, source, capture: :first))
end
