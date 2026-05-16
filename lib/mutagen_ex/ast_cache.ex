defmodule MutagenEx.AstCache do
  @moduledoc """
  Immutable cache of `{quoted_ast, source_text}` tuples for the in-scope
  source files of a `mix mutagen` run.

  Contract: [`mutagen.coverage`](../../.spec/specs/coverage.spec.md) r6, r9.

  ## Why both AST and verbatim source text

  Two consumers need different shapes:

    * `MutagenEx.MutationEnumerator` walks the AST to find candidate sites.
    * `MutagenEx.JsonReporter` (S6) renders a `before_source` field for each
      reported mutation.

  Current contract (see `mutagen.json_schema` r4 + r12, post
  `mutagen-wrd.34`): `before_source` is a verbatim source slice taken
  by `{line, column, end_line, end_column}` against `source_text`
  whenever the enumerator could derive end positions for the site
  (the common case for AST 3-tuples). When end positions are
  unavailable (bare-literal sites attributed to a parent operator,
  some macro-expanded forms) the renderer falls back to aliasing
  the `Macro.to_string(original_ast)` binary already computed for
  `before`. The slice path uses byte indexing and never invokes
  `Macro.to_string/1`, so the `2 * R` rendering call-count cap
  from r12 still holds.

  Holding the verbatim source bytes the AST was parsed from keeps
  the slice deterministic: it is the byte content of the file at
  load time, not what's on disk now (which a concurrent edit could
  have changed).

  Critical invariant (r6): `source_text` is byte-identical to
  `File.read!(file)` at the moment `load/1` was called. Each file is read
  exactly once.

  ## Categorised input (r9)

  `load/2` accepts an optional `:categories` opt whose value is a map
  from category name (atom) to a list of file paths
  (e.g. `categories: %{scope: scope_files, test: test_files}`). This is
  **input-only diagnostic metadata** — the cache entry shape is unchanged
  (`{Macro.t(), String.t()}`); there is no per-entry category tag, no
  3-tuple, no `files_by_category/2` consumer API. Categorisation is logged
  to telemetry-style diagnostics so observers can see "we loaded N scope
  files + M test files" without changing how downstream phases look up
  entries (they still call `get(cache, file)` by path).

  The flat `files` arg remains the source of truth for what gets read;
  category lists should be a partition of `files` (the implementation
  does NOT enforce this — categorisation is advisory).

  ## Immutability

  The cache is a plain `Map.t()`. There is no `put/3`, no `update/3`. Once
  `load/1` returns, callers can only `get/2`. This is the runtime-level
  enforcement of "the cache is immutable after the first build" (r6).
  """

  @behaviour MutagenEx.Pipeline.AstCacheFacade

  @typedoc "An entry in the cache. AST is whatever `Code.string_to_quoted/2` returns."
  @type entry :: {Macro.t(), String.t()}

  @typedoc "The cache itself: a map from relative file path to entry."
  @type t :: %{optional(String.t()) => entry()}

  @typedoc "Reason atoms surfaced when a file cannot be loaded or parsed."
  @type load_reason :: :file_read_failed | :parse_error

  @doc """
  Read and parse each file in `files` exactly once. Returns
  `{:ok, cache}` on full success, or `{:error, reason, details}` on the
  first file that fails to read or parse.

  Per r6, this is the only function that reads source files. The cache it
  returns is then handed unchanged to coverage, the mutation enumerator, and
  the mutation runner.

  ## Opts

    * `:reader` — `(file :: String.t() -> String.t())`. Defaults to
      `&File.read!/1`. The seam exists so the C1/C2 spike findings about
      `Code.compiler_options(debug_info: true)` don't bleed into this
      module: the cache is purely about source bytes + parsed AST and is
      tested against in-memory strings without touching disk.

    * `:categories` — `%{atom() => [String.t()]}`. Optional diagnostic
      partitioning of the flat `files` list (e.g.
      `%{scope: [...], test: [...]}`). Per r9 this is **input-only**: it
      does NOT change the cache entry shape, and there is no consumer API
      for looking up entries by category. The implementation logs the
      per-category counts to `Logger.debug/1` for observability.
  """
  @impl MutagenEx.Pipeline.AstCacheFacade
  @spec load([String.t()], keyword) ::
          {:ok, t()} | {:error, load_reason(), map()}
  def load(files, opts \\ []) when is_list(files) do
    reader = Keyword.get(opts, :reader, &File.read!/1)
    _ = log_categories(files, Keyword.get(opts, :categories))

    Enum.reduce_while(files, {:ok, %{}}, fn file, {:ok, acc} ->
      case load_one(file, reader) do
        {:ok, entry} -> {:cont, {:ok, Map.put(acc, file, entry)}}
        {:error, _reason, _details} = err -> {:halt, err}
      end
    end)
  end

  @doc """
  Fetch the `{ast, source}` entry for `file`, or `:error` if absent.
  """
  @spec get(t(), String.t()) :: {:ok, entry()} | :error
  def get(cache, file) when is_map(cache) and is_binary(file) do
    Map.fetch(cache, file)
  end

  @doc """
  List the file keys in the cache. Order is not guaranteed.
  """
  @spec files(t()) :: [String.t()]
  def files(cache) when is_map(cache), do: Map.keys(cache)

  # ---- internals ----

  require Logger

  # r9 diagnostics. We log the per-category count (not the file lists
  # themselves — those can be long) at debug level so a pipeline observer
  # can see "loaded N scope files + M test files" without forcing this
  # information into the entry shape. Returns :ok regardless; logging
  # failures are not load failures.
  defp log_categories(_files, nil), do: :ok

  defp log_categories(files, %{} = categories) do
    counts =
      Enum.map(categories, fn {name, list} when is_atom(name) and is_list(list) ->
        {name, length(list)}
      end)

    Logger.debug(fn ->
      "AstCache.load/2: total=#{length(files)} categories=#{inspect(counts)}"
    end)

    :ok
  rescue
    _ -> :ok
  end

  defp log_categories(_files, _other), do: :ok

  defp load_one(file, reader) do
    case read(file, reader) do
      {:ok, source_text} ->
        parse(file, source_text)

      {:error, _reason, _details} = err ->
        err
    end
  end

  defp read(file, reader) do
    try do
      {:ok, reader.(file)}
    rescue
      e ->
        {:error, :file_read_failed,
         %{
           file: file,
           message:
             MutagenEx.JsonReporter.Sanitizer.clean(
               "could not read source file #{inspect(file)}: #{Exception.message(e)}"
             )
         }}
    end
  end

  defp parse(file, source_text) do
    case Code.string_to_quoted(source_text,
           columns: true,
           token_metadata: true,
           file: file
         ) do
      {:ok, ast} ->
        {:ok, {ast, source_text}}

      {:error, {meta_or_line, description, token}} ->
        line = parse_error_line(meta_or_line)

        {:error, :parse_error,
         %{
           file: file,
           line: line,
           message:
             MutagenEx.JsonReporter.Sanitizer.clean(
               "could not parse #{inspect(file)} at line #{line}: " <>
                 IO.iodata_to_binary(format_parse_error(description, token))
             )
         }}
    end
  end

  defp parse_error_line(line) when is_integer(line), do: line

  defp parse_error_line(meta) when is_list(meta) do
    Keyword.get(meta, :line, 0)
  end

  defp parse_error_line(_), do: 0

  defp format_parse_error(description, token) when is_binary(description) do
    [description, inspect(token)]
  end

  defp format_parse_error({prefix, suffix}, token)
       when is_binary(prefix) and is_binary(suffix) do
    [prefix, suffix, " ", inspect(token)]
  end

  defp format_parse_error(description, token) do
    [inspect(description), " ", inspect(token)]
  end
end
