defmodule MutagenEx.TestSelector do
  @moduledoc """
  Resolves user-supplied `--tests` targets into the `{include, exclude, files}`
  shape ExUnit's filter system expects.

  Contract: [`mutagen.test_selection`](../../.spec/specs/test_selection.spec.md).

  Three target shapes are recognised:

    * A whole test file: `test/foo_test.exs`
    * A specific test inside a file: `test/foo_test.exs:42`
    * A tag: `tag:integration`

  Tag resolution walks `test/**/*_test.exs` via `Code.string_to_quoted/2`. It
  does **not** load the test modules — loading them would trip the state
  hygiene contract carried by `mutagen.mutation_pipeline`. The selector
  therefore remains usable from any process without ExUnit being running.

  A target that resolves to zero matching tests (e.g. `tag:unused` with no
  matching `@tag :unused` anywhere, or a `:line` that points outside every
  test block in the named file) returns a structured `{:error, ...}` tuple
  rather than an empty filter.

  ## Return shape

  Successful resolution returns `{:ok, %TestFilter{include, exclude, files}}`.

  Multiple targets compose by union: `files` and `include` are the
  deduplicated union of each target's contribution. `exclude` is always
  `[:test]`, matching ExUnit's documented "include + exclude :test" pattern
  for running only the named files / tags.
  """

  alias MutagenEx.TestSelector.TestFilter

  defmodule TestFilter do
    @moduledoc """
    The resolved ExUnit-shaped filter.

    `include` and `exclude` are passed to `ExUnit.configure/1`; `files` is the
    list of paths handed to `Kernel.ParallelCompiler.require/1` (or
    equivalent) at runtime. The selector itself never loads these files —
    that's the runner's job in `mutagen.mutation_pipeline`.
    """

    @enforce_keys [:include, :exclude, :files]
    defstruct include: [], exclude: [:test], files: []

    @type t :: %__MODULE__{
            include: [atom() | {:location, {String.t(), pos_integer()}}],
            exclude: [atom()],
            files: [String.t()]
          }
  end

  @type target :: String.t()
  @type error_reason ::
          :no_tests_match
          | :invalid_target
          | :invalid_line
          | :file_not_found
          | :tag_walk_failed

  @typedoc "Options accepted by `resolve/2`."
  @type option :: {:test_root, String.t()}
  @type options :: [option()]

  @doc """
  Resolves one or more `--tests` targets to a single `TestFilter`.

  ## Options

    * `:test_root` — directory to walk for `tag:NAME` resolution. Defaults
      to `"test"`. Exposed so the test suite can point at fixture trees
      without polluting the real `test/` directory.

  Targets compose by union; duplicates collapse. If any target fails to
  resolve (unknown shape, no matching tests, file not found), the first
  failure is returned and no filter is produced.
  """
  @spec resolve(target() | [target()], options()) ::
          {:ok, TestFilter.t()} | {:error, %{reason: error_reason(), target: target()}}
  def resolve(target, opts \\ [])

  def resolve(target, opts) when is_binary(target) do
    resolve([target], opts)
  end

  def resolve(targets, opts) when is_list(targets) do
    test_root = Keyword.get(opts, :test_root, "test")

    Enum.reduce_while(targets, {:ok, %TestFilter{include: [], exclude: [:test], files: []}}, fn
      target, {:ok, acc} ->
        case resolve_one(target, test_root) do
          {:ok, %TestFilter{} = filter} -> {:cont, {:ok, merge(acc, filter)}}
          {:error, _} = err -> {:halt, err}
        end
    end)
  end

  # ---------------------------------------------------------------------------
  # Per-target resolution
  # ---------------------------------------------------------------------------

  @spec resolve_one(target(), String.t()) ::
          {:ok, TestFilter.t()} | {:error, %{reason: error_reason(), target: target()}}
  defp resolve_one("tag:" <> name, test_root) when name != "" do
    resolve_tag(name, test_root)
  end

  defp resolve_one(target, _test_root) when is_binary(target) do
    cond do
      String.match?(target, ~r/_test\.exs:\d+$/) ->
        resolve_file_line(target)

      String.ends_with?(target, "_test.exs") ->
        resolve_file(target)

      true ->
        {:error, %{reason: :invalid_target, target: target}}
    end
  end

  defp resolve_one(target, _test_root) do
    {:error, %{reason: :invalid_target, target: target}}
  end

  # `<path>_test.exs`
  defp resolve_file(path) do
    {:ok, %TestFilter{include: [], exclude: [:test], files: [path]}}
  end

  # `<path>_test.exs:<line>`
  defp resolve_file_line(target) do
    [path, line_str] = String.split(target, ":", parts: 2)

    with {line, ""} when line > 0 <- Integer.parse(line_str),
         true <- line_inside_test_block?(path, line) do
      {:ok,
       %TestFilter{
         include: [{:location, {path, line}}],
         exclude: [:test],
         files: [path]
       }}
    else
      false ->
        {:error, %{reason: :no_tests_match, target: target}}

      _ ->
        {:error, %{reason: :invalid_line, target: target}}
    end
  end

  # Walks `path` looking for `test "..."` or `test "...", do: ...` blocks
  # whose line span includes `line`. A test "block" spans from its starting
  # line through its `end` line; when no end metadata is available (e.g. the
  # AST node is a do/end keyword form), we accept any line >= the start.
  @spec line_inside_test_block?(String.t(), pos_integer()) :: boolean()
  defp line_inside_test_block?(path, line) do
    with {:ok, source} <- File.read(path),
         {:ok, quoted} <- Code.string_to_quoted(source, columns: true) do
      ranges = collect_test_ranges(quoted)
      Enum.any?(ranges, fn {start, finish} -> line >= start and line <= finish end)
    else
      _ -> false
    end
  end

  defp collect_test_ranges(ast) do
    {_, ranges} =
      Macro.prewalk(ast, [], fn
        {:test, meta, args} = node, acc when is_list(args) ->
          {node, [test_range(meta, args) | acc]}

        node, acc ->
          {node, acc}
      end)

    ranges
    |> Enum.reject(&is_nil/1)
  end

  defp test_range(meta, args) do
    start = Keyword.get(meta, :line)

    if is_integer(start) do
      finish = test_block_end(args, start)
      {start, finish}
    else
      nil
    end
  end

  defp test_block_end(args, start) do
    args
    |> List.last()
    |> extract_end_line()
    |> case do
      nil -> start
      finish when finish < start -> start
      finish -> finish
    end
  end

  defp extract_end_line([{:do, body} | _]) do
    case body do
      {_, meta, _} ->
        Keyword.get(meta, :end, []) |> case do
          [{:line, line} | _] -> line
          _ -> last_line_of(body)
        end

      _ ->
        nil
    end
  end

  defp extract_end_line({_, meta, _}) do
    case Keyword.get(meta, :end, nil) do
      [{:line, line} | _] -> line
      _ -> Keyword.get(meta, :line)
    end
  end

  defp extract_end_line(_), do: nil

  defp last_line_of({_, meta, args}) when is_list(meta) and is_list(args) do
    line = Keyword.get(meta, :line)

    args
    |> Enum.flat_map(fn
      {_, m, a} when is_list(m) and is_list(a) -> [last_line_of({nil, m, a})]
      _ -> []
    end)
    |> Enum.concat([line])
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      lines -> Enum.max(lines)
    end
  end

  defp last_line_of(_), do: nil

  # `tag:<name>` — AST-walk test_root for files containing `@tag :<name>` on a
  # `test` or `describe` block.
  defp resolve_tag(name, test_root) do
    tag_atom = String.to_atom(name)
    target = "tag:" <> name

    case scan_for_tag(test_root, tag_atom) do
      {:ok, []} ->
        {:error, %{reason: :no_tests_match, target: target}}

      {:ok, files} ->
        {:ok,
         %TestFilter{
           include: [tag_atom],
           exclude: [:test],
           files: Enum.sort(files)
         }}

      {:error, reason} ->
        {:error, %{reason: reason, target: target}}
    end
  end

  # ---------------------------------------------------------------------------
  # AST walking
  # ---------------------------------------------------------------------------

  @spec scan_for_tag(String.t(), atom()) :: {:ok, [String.t()]} | {:error, error_reason()}
  defp scan_for_tag(test_root, tag_atom) do
    case File.dir?(test_root) do
      false ->
        {:error, :file_not_found}

      true ->
        files =
          test_root
          |> walk_test_files()
          |> Enum.filter(&file_contains_tag?(&1, tag_atom))

        {:ok, files}
    end
  end

  @doc false
  # Walks `dir` and returns every regular file matching `*_test.exs`. The walk
  # is intentionally manual (no `Path.wildcard/1`) so the function works with
  # arbitrary nesting depth without recompiling globs.
  @spec walk_test_files(String.t()) :: [String.t()]
  def walk_test_files(dir) do
    walk_test_files(dir, [])
  end

  defp walk_test_files(dir, acc) do
    case File.ls(dir) do
      {:ok, entries} ->
        Enum.reduce(entries, acc, fn entry, inner_acc ->
          path = Path.join(dir, entry)

          cond do
            File.dir?(path) ->
              walk_test_files(path, inner_acc)

            String.ends_with?(entry, "_test.exs") ->
              [path | inner_acc]

            true ->
              inner_acc
          end
        end)

      {:error, _} ->
        acc
    end
  end

  # Loads `path`'s source, parses with `Code.string_to_quoted/2`, and walks
  # the resulting quoted form looking for any `@tag :<tag_atom>` attribute.
  # Returns `false` (do not include) for files that cannot be read or parsed
  # — those are not crashes of the selector, they're just files that don't
  # contribute to the tag set.
  @spec file_contains_tag?(String.t(), atom()) :: boolean()
  defp file_contains_tag?(path, tag_atom) do
    with {:ok, source} <- File.read(path),
         {:ok, quoted} <- Code.string_to_quoted(source) do
      ast_contains_tag?(quoted, tag_atom)
    else
      _ -> false
    end
  end

  # Walks an AST node looking for an `@tag :<tag_atom>` attribute. Recognises
  # both `@tag :name` and `@tag name: value` forms (the latter is matched
  # only when `name == tag_atom`, since ExUnit treats keyword-style tags
  # equivalently for filtering).
  defp ast_contains_tag?(ast, tag_atom) do
    {_, found} =
      Macro.prewalk(ast, false, fn
        _node, true = acc ->
          {nil, acc}

        {:@, _, [{:tag, _, [arg]}]} = node, _acc ->
          if tag_matches?(arg, tag_atom) do
            {node, true}
          else
            {node, false}
          end

        node, acc ->
          {node, acc}
      end)

    found
  end

  # `@tag :foo` → arg is the atom `:foo`
  defp tag_matches?(arg, tag_atom) when is_atom(arg), do: arg == tag_atom

  # `@tag foo: true` → arg is `[foo: true]`
  defp tag_matches?(arg, tag_atom) when is_list(arg) do
    Enum.any?(arg, fn
      {^tag_atom, _} -> true
      _ -> false
    end)
  end

  defp tag_matches?(_arg, _tag_atom), do: false

  # ---------------------------------------------------------------------------
  # Merge / dedup
  # ---------------------------------------------------------------------------

  @spec merge(TestFilter.t(), TestFilter.t()) :: TestFilter.t()
  defp merge(%TestFilter{} = a, %TestFilter{} = b) do
    %TestFilter{
      include: dedup_preserve_order(a.include ++ b.include),
      exclude: a.exclude,
      files: dedup_preserve_order(a.files ++ b.files)
    }
  end

  defp dedup_preserve_order(list) do
    {result, _} =
      Enum.reduce(list, {[], MapSet.new()}, fn item, {acc, seen} ->
        if MapSet.member?(seen, item) do
          {acc, seen}
        else
          {[item | acc], MapSet.put(seen, item)}
        end
      end)

    Enum.reverse(result)
  end
end
