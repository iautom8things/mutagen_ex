defmodule MutagenEx.TestModuleDiscovery do
  @moduledoc """
  Finds loaded ExUnit cases in the cited test files.

  ExUnit consumes the registered case list on each run. Coverage, baseline,
  and mutation use this list to register the same cases again without
  compiling the files again.
  """

  @typedoc "ExUnit case configuration with serial execution."
  @type module_cfg :: %{async?: false, group: term(), parameterize: [map()] | nil}

  @typedoc "A case and its registration options."
  @type entry :: {module(), module_cfg()}

  @doc """
  Return loaded modules whose compile source is a cited path and that
  export `__ex_unit__/0`. Call after requiring the files. Entries follow
  the caller's file order, then declaration order within each file.
  Cases without a source declaration follow in module name order.
  A cited symlink to a case compiled under a different path returns
  `{:error, :test_file_load_failed, details}`.
  """
  @spec discover([Path.t()]) :: [entry()] | {:error, :test_file_load_failed, map()}
  def discover([]), do: []

  def discover(files) do
    by_source =
      :code.all_loaded()
      |> Enum.flat_map(fn {module, _beam} ->
        if function_exported?(module, :__ex_unit__, 0) do
          [{module.module_info(:compile)[:source], module}]
        else
          []
        end
      end)
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

    files
    |> Enum.map(&Path.expand/1)
    |> Enum.uniq()
    |> Enum.reduce_while([], fn file, groups ->
      case Map.get(by_source, String.to_charlist(file), []) do
        [] ->
          case linked_source(file, by_source) do
            nil ->
              {:cont, groups}

            source ->
              {:halt,
               {:error, :test_file_load_failed,
                %{
                  file: file,
                  message:
                    "Cited symlink #{inspect(file)} does not match the compiled source path " <>
                      "#{inspect(List.to_string(source))}. Cite the test file's real path instead of the symlink."
                }}}
          end

        modules ->
          entries =
            for module <- in_declaration_order(modules, file) do
              {module, Map.put(module.__ex_unit__(:config), :async?, false)}
            end

          {:cont, [entries | groups]}
      end
    end)
    |> case do
      groups when is_list(groups) -> groups |> Enum.reverse() |> List.flatten()
      error -> error
    end
  end

  @doc false
  def for_tests(%{test_modules: modules}), do: modules
  def for_tests(%{test_filter: %{files: files}}), do: discover(files)

  defp linked_source(file, by_source) do
    if symlink_path?(file) do
      case file_identity(file) do
        nil -> nil
        identity -> Enum.find(Map.keys(by_source), &(file_identity(&1) == identity))
      end
    end
  end

  defp file_identity(file) do
    case File.stat(file) do
      {:ok, %{inode: inode, major_device: major, minor_device: minor}} -> {inode, major, minor}
      _ -> nil
    end
  end

  defp symlink_path?(file) do
    case File.lstat(file) do
      {:ok, %{type: :symlink}} ->
        true

      {:ok, _} ->
        parent = Path.dirname(file)
        parent != file and symlink_path?(parent)

      _ ->
        false
    end
  end

  defp in_declaration_order([_, _ | _] = modules, file) do
    with {:ok, source} <- File.read(file),
         {:ok, ast} <- Code.string_to_quoted(source) do
      declared =
        for {module, _, _} <- MutagenEx.Ast.module_blocks(ast), module in modules, uniq: true do
          module
        end

      declared ++ Enum.sort(modules -- declared)
    else
      _ -> Enum.sort(modules)
    end
  end

  defp in_declaration_order(modules, _file), do: modules
end
