defmodule MutagenEx.TestModuleDiscovery do
  @moduledoc """
  Finds loaded ExUnit cases in the cited test files.

  ExUnit consumes the registered case list on each run. Coverage, baseline,
  and mutation use this list to register the same cases again without
  compiling the files again.
  """

  @typedoc "Configuration for serial, unparameterized case registration."
  @type module_cfg :: %{async?: false, group: nil, parameterize: nil}

  @typedoc "A case and its registration options."
  @type entry :: {module(), module_cfg()}

  @doc """
  Return loaded modules whose compile source is a cited path and that
  export `__ex_unit__/0`. Call after requiring the files. Entries follow
  the caller's file order, then declaration order within each file.
  Cases without a source declaration follow in module name order.
  """
  @spec discover([Path.t()]) :: [entry()]
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
    |> Enum.map(fn file -> file |> Path.expand() |> String.to_charlist() end)
    |> Enum.uniq()
    |> Enum.flat_map(fn file ->
      for module <- in_declaration_order(Map.get(by_source, file, []), file) do
        {module, %{async?: false, group: nil, parameterize: nil}}
      end
    end)
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
