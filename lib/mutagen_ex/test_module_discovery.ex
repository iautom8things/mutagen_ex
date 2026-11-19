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
  the caller's file order, with modules in each file sorted by name.
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
      for module <- Enum.sort(Map.get(by_source, file, [])) do
        {module, %{async?: false, group: nil, parameterize: nil}}
      end
    end)
  end
end
