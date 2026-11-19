defmodule MutagenEx.AutoTests do
  @moduledoc false

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

  def discover(stage, survivors, paths, tried, cap) do
    patterns = patterns(stage, survivors)

    matches =
      if patterns == [] do
        []
      else
        tried = MapSet.new(tried, &file_identity/1)

        paths
        |> Enum.flat_map(&Path.wildcard(Path.join(&1, "**/*_test.exs")))
        |> Enum.sort()
        |> Enum.filter(&regular_path?/1)
        |> Enum.uniq_by(&file_identity/1)
        |> Enum.reject(&MapSet.member?(tried, file_identity(&1)))
        |> Enum.flat_map(&score_file(&1, patterns))
        |> Enum.sort_by(fn {path, score} -> {-score, path} end)
      end

    {Enum.map(Enum.take(matches, cap), &elem(&1, 0)), length(matches) > cap}
  end

  defp file_identity(path) do
    case File.lstat(path) do
      {:ok, %{type: :regular} = stat} ->
        {stat.major_device, stat.minor_device, stat.inode}

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
         {:ok, stat} <- File.stat(root),
         {:ok, other} <- File.stat(Path.join(prefix)),
         true <- stat.inode == other.inode and stat.major_device == other.major_device do
      {:ok, Path.join(relative)}
    else
      _ -> :error
    end
  end

  defp score_file(path, patterns) do
    with {:ok, source} <- File.read(path),
         score when score > 0 <- Enum.sum_by(patterns, &count_matches(&1, source)) do
      [{path, score}]
    else
      _ -> []
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

  defp patterns(stage, survivors) do
    survivors
    |> Enum.flat_map(fn
      %{function: mfa} when is_binary(mfa) ->
        case Regex.run(~r/\A(.+)\.([^.]+)\/([0-9]+)\z/, mfa, capture: :all_but_first) do
          [module, name, arity] -> [{module, name, arity}]
          nil -> []
        end

      _ ->
        []
    end)
    |> build_patterns(stage)
  end

  defp build_patterns(mfas, :module) do
    mfas
    |> Enum.uniq_by(&elem(&1, 0))
    |> Enum.map(fn {module, _, _} ->
      {parent, last} = module_parts(module)

      full =
        Regex.compile!(
          "(?<![A-Za-z0-9_.])(?:Elixir\\.)?" <> Regex.escape(module) <> "(?![A-Za-z0-9_])"
        )

      alias_parent =
        if parent != "" do
          Regex.compile!(
            "\\balias\\s+(?:Elixir\\.)?" <> Regex.escape(parent) <> "(?![A-Za-z0-9_.])"
          )
        end

      {:module, full, alias_parent, Regex.compile!("\\b" <> Regex.escape(last) <> "\\b")}
    end)
  end

  defp build_patterns(mfas, :function) do
    mfas
    |> Enum.uniq()
    |> Enum.map(fn {module, name, arity} ->
      {_, last} = module_parts(module)
      name = Regex.escape(name)

      regex =
        Regex.compile!(
          "(?<![A-Za-z0-9_])" <>
            name <>
            "\\s*\\(|&(?:[A-Za-z0-9_.]+\\.)?" <> name <> "\\s*/\\s*" <> arity <> "(?![0-9])"
        )

      {:function, last, regex}
    end)
  end

  defp module_parts(module) do
    [last | parent] = module |> String.split(".") |> Enum.reverse()
    {Enum.join(Enum.reverse(parent), "."), last}
  end

  defp count_matches({:module, full, parent_alias, last}, source) do
    case Regex.scan(full, source) do
      [] ->
        if parent_alias && Regex.match?(parent_alias, source),
          do: length(Regex.scan(last, source)),
          else: 0

      matches ->
        length(matches)
    end
  end

  defp count_matches({:function, last, regex}, source) do
    if :binary.match(source, last) == :nomatch, do: 0, else: length(Regex.scan(regex, source))
  end
end
