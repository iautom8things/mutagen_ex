defmodule MutagenEx.AstCache do
  @moduledoc """
  Immutable cache of `{quoted_ast, source_text}` tuples for the in-scope
  source files of a `mix mutagen` run.

  Contract: [`mutagen.coverage`](../../.spec/specs/coverage.spec.md) r6.

  ## Why both AST and verbatim source text

  Two consumers need different shapes:

    * `MutagenEx.MutationEnumerator` walks the AST to find candidate sites.
    * `MutagenEx.JsonReporter` (S6) cuts a `before_source` slice for each
      reported mutation. The slice is taken by `{line, column, end_line,
      end_column}` from AST node metadata against the **verbatim** source
      text — so format-equivalent but byte-different re-serialisations of
      the AST would break the slice contract. Holding the verbatim source
      bytes that the AST was parsed from is the cleanest way to keep the
      slice deterministic.

  Critical invariant (r6): `source_text` is byte-identical to
  `File.read!(file)` at the moment `load/1` was called. Each file is read
  exactly once.

  ## Immutability

  The cache is a plain `Map.t()`. There is no `put/3`, no `update/3`. Once
  `load/1` returns, callers can only `get/2`. This is the runtime-level
  enforcement of "the cache is immutable after the first build" (r6).
  """

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
  """
  @spec load([String.t()], keyword) ::
          {:ok, t()} | {:error, load_reason(), map()}
  def load(files, opts \\ []) when is_list(files) do
    reader = Keyword.get(opts, :reader, &File.read!/1)

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
