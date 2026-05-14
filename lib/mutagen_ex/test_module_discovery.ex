defmodule MutagenEx.TestModuleDiscovery do
  @moduledoc """
  Discovers the ExUnit test modules declared in a set of cited test files
  without loading them, so the production pipeline can populate the
  `test_modules` payload that `MutationRunner` / `MutationLoop` re-registers
  via `ExUnit.Server.add_module/2` before each per-site `ExUnit.run/0`.

  ## Why this exists

  `MutationLoop.execute_with_timeout/1` re-registers every entry in
  `input.test_modules` before each per-site test run because Elixir's
  `ExUnit.Server` consumes its registered-module list at every
  `ExUnit.run/0` invocation. Without re-registration, the second and
  subsequent sites would run zero tests and every mutation would be
  classified `:survived` — see `mutagen.mutation_pipeline.r5`.

  Production must therefore hand `MutationRunner` an accurate list of
  `{module, exunit_module_cfg}` tuples derived from the cited test files.
  This module is that derivation: a pure-AST walk over each cited
  `*_test.exs`, picking out every `defmodule` block's alias and packaging
  it with the `%{async?: false, group: nil, parameterize: nil}` config map
  that `ExUnit.Server.add_module/2` consumes (shape validated by the S2
  spike against Elixir 1.19.5/OTP 28).

  ## What this module does NOT do

  - It does not load or compile the cited files. The S7 end-to-end
    driver and the production baseline/coverage phases handle that via
    `Code.compile_file/1` (which fires the `use ExUnit.Case`
    `__after_compile__` hook and is the side-effect path that actually
    makes the cited modules resolvable as atoms at the BEAM level). This
    module's only contract is the data needed for the per-site
    re-registration loop.
  - It does not consult `use ExUnit.Case, async: true` to set the
    `async?` flag. Per `mutagen.mutation_pipeline.r2`, the runner forces
    `max_cases: 1` regardless of source-level `async:` declarations; the
    async-true warning lives in `MutagenEx.Baseline` and is independent
    of this payload.

  ## Failure modes

  Unreadable or unparseable cited files contribute zero modules and emit
  no error from `discover/1`. The CLI / scope-resolution phase is the
  point at which bad cited test paths surface as a user-facing error; by
  the time the mutation phase begins, every entry in `test_filter.files`
  has been validated. A defensive empty-list-on-error here keeps the
  mutation phase from crashing on a transient FS race after that gate.
  """

  @typedoc """
  ExUnit module configuration map that `ExUnit.Server.add_module/2`
  consumes. The S2 spike validated this exact shape against Elixir
  1.19.5; if ExUnit's internal config struct changes, this is the line
  to update (and the spike will catch the regression).
  """
  @type module_cfg :: %{async?: false, group: nil, parameterize: nil}

  @typedoc "One entry of the `test_modules` list `MutationRunner.run/1` consumes."
  @type entry :: {module(), module_cfg()}

  @doc """
  Walk the AST of each cited test file and return `{module, cfg}` tuples
  for every `defmodule` declaration found, in source order.

  Ignores files that cannot be read or parsed (returns no entries for
  them rather than raising — see the moduledoc's "Failure modes"
  section).

  ## Examples

      iex> MutagenEx.TestModuleDiscovery.discover([])
      []

      iex> # A real cited test file with one defmodule produces one entry
      iex> file = Path.join(System.tmp_dir!(), "mutagen_ex_disc_doctest.exs")
      iex> File.write!(file, ~s|defmodule SomeTest do\\nend\\n|)
      iex> result = MutagenEx.TestModuleDiscovery.discover([file])
      iex> File.rm!(file)
      iex> result
      [{SomeTest, %{async?: false, group: nil, parameterize: nil}}]
  """
  @spec discover([Path.t()]) :: [entry()]
  def discover(files) when is_list(files) do
    Enum.flat_map(files, &discover_in_file/1)
  end

  defp discover_in_file(file) do
    with {:ok, source} <- File.read(file),
         {:ok, ast} <- Code.string_to_quoted(source, file: file) do
      ast
      |> collect_defmodule_aliases()
      |> Enum.map(&{&1, default_cfg()})
    else
      _ -> []
    end
  end

  # Walk the AST and collect every `defmodule Alias do ... end` head in
  # source order. `prewalk` accumulates in reverse; we flip at the end
  # so the result reflects the order the modules appear in the source.
  defp collect_defmodule_aliases(ast) do
    {_, acc} =
      Macro.prewalk(ast, [], fn
        {:defmodule, _meta, [alias_ast, [do: _body]]} = node, acc ->
          case alias_to_module(alias_ast) do
            nil -> {node, acc}
            mod -> {node, [mod | acc]}
          end

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(acc)
  end

  defp alias_to_module({:__aliases__, _meta, parts}) when is_list(parts) do
    if Enum.all?(parts, &is_atom/1), do: Module.concat(parts), else: nil
  end

  defp alias_to_module(mod) when is_atom(mod), do: mod
  defp alias_to_module(_), do: nil

  defp default_cfg, do: %{async?: false, group: nil, parameterize: nil}
end
