defmodule MutagenEx.JsonReporter.Provenance do
  @moduledoc false

  def compiled_module?(module) when is_atom(module) do
    case :code.which(module) do
      :preloaded ->
        true

      [_ | _] = path ->
        path = Path.expand(to_string(path))
        File.regular?(path) and Enum.any?(beam_roots(), &inside?(path, &1))

      _ ->
        false
    end
  end

  def compiled_module?(_), do: false

  def stack_locations(stack) do
    for {module, _, _, meta} <- stack,
        file = meta[:file],
        line = meta[:line],
        is_integer(line),
        path = project_path(to_string(file), module) do
      {path, line}
    end
  end

  defp project_path(file, module) do
    root = File.cwd!()
    absolute = Path.expand(file, root)

    if inside?(absolute, root) and File.regular?(absolute) and
         (Path.type(file) == :absolute or not toolchain_module?(module)) do
      Path.relative_to(absolute, root)
    end
  end

  defp toolchain_module?(module) do
    case :code.which(module) do
      [_ | _] = path -> Enum.any?(toolchain_roots(), &inside?(Path.expand(to_string(path)), &1))
      :preloaded -> true
      _ -> false
    end
  end

  defp beam_roots do
    project =
      if Process.whereis(Mix.ProjectStack) && Mix.Project.get() do
        [
          Mix.Project.compile_path(),
          Path.join(Mix.Project.build_path(), "lib"),
          Mix.Project.deps_path()
        ]
      else
        []
      end

    toolchain_roots() ++ project
  end

  defp toolchain_roots do
    [to_string(:code.lib_dir()), :elixir |> :code.lib_dir() |> to_string() |> Path.dirname()]
  end

  defp inside?(path, root), do: String.starts_with?(path, Path.expand(root) <> "/")
end
