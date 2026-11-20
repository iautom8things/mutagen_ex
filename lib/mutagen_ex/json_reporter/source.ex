defmodule MutagenEx.JsonReporter.Source do
  @moduledoc false

  # Keep literal positions in a separate tree for source excerpts and cover
  # attribution. Mutation and site identity use the original AST.
  def index(source, file) do
    key = make_ref()
    Process.put(key, %{})

    try do
      build_index(source, file, key)
    after
      Process.delete(key)
    end
  end

  defp build_index(source, file, key) do
    options = [columns: true, token_metadata: true, emit_warnings: false]

    # Tokenize a coordinate-only copy so the compiler recognizes quoted
    # regions and interpolation without a second string lexer here.
    with {:ok, tokens, coordinates} <- tokenize_with_coordinates(source, file, options, key),
         {:ok, ast} <-
           :elixir.tokens_to_quoted(tokens, file, [literal_encoder: &wrap_literal/2] ++ options),
         context = %{source: source, offsets: byte_offsets(source), comments: Process.get(key)},
         {:ok, ranges} <- token_ranges(tokens, coordinates, byte_size(source), context, %{}) do
      {ast, ranges}
    else
      _ -> nil
    end
  end

  defp tokenize_with_coordinates(source, file, options, key) do
    case split_graphemes(source) do
      ^source ->
        with {:ok, tokens} <- tokenize(source, file, options, key), do: {:ok, tokens, tokens}

      coordinate_source ->
        coordinate_options = [static_atoms_encoder: fn name, _ -> {:ok, name} end] ++ options

        with {:ok, coordinates} <- tokenize(coordinate_source, file, coordinate_options, key),
             {:ok, tokens} <-
               :elixir.string_to_tokens(String.to_charlist(source), 1, 1, file, options) do
          {:ok, tokens, coordinates}
        end
    end
  end

  defp tokenize(source, file, options, key) do
    preserve_comments = fn line, column, tokens, _, _ ->
      case tokens do
        [previous | _] ->
          Process.put(
            key,
            Map.put_new(Process.get(key), token_position(previous), {line, column})
          )

        [] ->
          :ok
      end
    end

    :elixir.string_to_tokens(
      String.to_charlist(source),
      1,
      1,
      file,
      [preserve_comments: preserve_comments] ++ options
    )
  end

  defp split_graphemes(source) do
    if Regex.match?(~r/[^\x00-\x7f]/, source) do
      for grapheme <- String.graphemes(source), into: "", do: split_grapheme(grapheme)
    else
      source
    end
  end

  defp split_grapheme(<<_point::utf8>> = single), do: single
  defp split_grapheme("\r\n"), do: "\r\n"

  # Preserve ASCII syntax and the case of identifier starts. Each
  # replacement occupies one code point in the original byte index.
  defp split_grapheme(grapheme) do
    for <<point::utf8 <- grapheme>>, into: "" do
      cond do
        point < 128 -> <<point>>
        Regex.match?(~r/^[\p{Lu}\p{Lt}]$/u, <<point::utf8>>) -> "X"
        true -> "x"
      end
    end
  end

  defp wrap_literal(value, metadata),
    do: {:ok, {:__block__, [{:mutagen_literal, true} | metadata], [value]}}

  def span(index, path) do
    case located_span(index, path) do
      {span, _line} -> span
      nil -> nil
    end
  end

  def located_span({ast, ranges}, path) do
    with node when not is_nil(node) <- at_path(ast, path),
         {line, _} = position <- start_position(node),
         {start, _} <- Map.get(ranges, position),
         {_, stop} <- Map.get(ranges, last_token(node)),
         true <- start < stop do
      {{start, stop - start}, line}
    else
      _ -> nil
    end
  end

  def located_span(nil, _path), do: nil

  def line_range({ast, _ranges}, path) do
    with node when not is_nil(node) <- at_path(ast, path),
         {first, _} <- start_position(node),
         {last, _} <- last_token(node) do
      {first, last}
    else
      _ -> nil
    end
  end

  def line_range(nil, _path), do: nil

  defp at_path(node, []), do: node

  defp at_path({:__block__, meta, [literal]}, path) do
    case {meta[:mutagen_literal], path} do
      {true, path} -> at_path(literal, path)
      {nil, [{:arg, 0} | rest]} -> at_path(literal, rest)
      _ -> nil
    end
  end

  defp at_path({form, _, _}, [:form | path]), do: at_path(form, path)

  defp at_path({_, _, args}, [{:arg, index} | path]) when is_list(args),
    do: at_path(Enum.at(args, index), path)

  defp at_path({left, _}, [:left | path]), do: at_path(left, path)
  defp at_path({_, right}, [:right | path]), do: at_path(right, path)

  defp at_path(list, [{:elem, index} | path]) when is_list(list),
    do: at_path(Enum.at(list, index), path)

  defp at_path(_, _), do: nil

  defp start_position({form, meta, args}) when is_list(meta) do
    case position(meta[:parens]) do
      nil -> earliest([position(meta), start_position(form), start_position(args)])
      start -> start
    end
  end

  defp start_position({left, right}), do: start_position(left) || start_position(right)
  defp start_position([head | tail]), do: start_position(head) || start_position(tail)
  defp start_position(_), do: nil

  defp earliest(positions), do: positions |> Enum.reject(&is_nil/1) |> Enum.min(fn -> nil end)

  defp last_token({form, meta, args}) when is_list(meta) do
    position(meta[:parens][:closing]) || position(meta[:end]) || position(meta[:closing]) ||
      position(meta[:last]) || last_child(form, meta, args)
  end

  defp last_token({_, right}), do: last_token(right)
  defp last_token(list) when is_list(list), do: list |> List.last() |> last_token()
  defp last_token(_), do: nil

  defp last_child(_form, meta, args) do
    if meta[:mutagen_literal] || meta[:delimiter],
      do: position(meta),
      else: last_token(args) || position(meta)
  end

  defp position(meta) do
    case {meta[:line], meta[:column]} do
      {line, column} when is_integer(line) and is_integer(column) -> {line, column}
      _ -> nil
    end
  end

  defp token_position(token) do
    {line, column, _} = elem(token, 1)
    {line, column}
  end

  defp byte_offsets(source) do
    for <<point::utf8 <- source>>, reduce: {%{}, 1, 1, 0} do
      {offsets, line, column, byte} ->
        offsets = Map.put(offsets, {line, column}, byte)

        case point do
          ?\n -> {offsets, line + 1, 1, byte + 1}
          _ -> {offsets, line, column + 1, byte + byte_size(<<point::utf8>>)}
        end
    end
    |> then(fn {offsets, line, column, byte} -> Map.put(offsets, {line, column}, byte) end)
  end

  defp token_ranges(tokens, coordinates, stop, context, ranges)
       when length(tokens) == length(coordinates) do
    tokens
    |> Enum.reverse()
    |> Enum.zip(Enum.reverse(coordinates))
    |> Enum.reduce_while({:ok, stop, ranges}, fn {token, coordinate}, {:ok, stop, ranges} ->
      {line, _} = position = token_position(token)
      coordinate_position = token_position(coordinate)

      with true <- elem(token, 0) == elem(coordinate, 0) and elem(coordinate_position, 0) == line,
           {:ok, start} <- Map.fetch(context.offsets, coordinate_position),
           token_ranges =
             put_range(ranges, position, coordinate_position, start, stop, context),
           {:ok, ranges} <- add_interpolations(token, coordinate, context, token_ranges) do
        {:cont, {:ok, start, ranges}}
      else
        _ -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, _, ranges} -> {:ok, ranges}
      :error -> :error
    end
  end

  defp token_ranges(_, _, _, _, _), do: :error

  defp put_range(ranges, position, coordinate, start, stop, context) do
    limit = Map.get(context.offsets, Map.get(context.comments, coordinate), stop) |> min(stop)

    if start < limit do
      text = binary_part(context.source, start, limit - start)
      Map.put(ranges, position, {start, start + byte_size(String.trim_trailing(text))})
    else
      ranges
    end
  end

  defp add_interpolations(token, coordinate, context, ranges) do
    inner_tokens = for {_, _, tokens} <- interpolation_parts(token), do: tokens

    inner_coordinates =
      for {_, {line, column, _}, tokens} <- interpolation_parts(coordinate),
          do: {{line, column}, tokens}

    if length(inner_tokens) == length(inner_coordinates) do
      inner_tokens
      |> Enum.zip(inner_coordinates)
      |> Enum.reduce_while({:ok, ranges}, fn {tokens, {stop, coordinates}}, {:ok, ranges} ->
        with {:ok, stop} <- Map.fetch(context.offsets, stop),
             {:ok, ranges} <- token_ranges(tokens, coordinates, stop, context, ranges) do
          {:cont, {:ok, ranges}}
        else
          _ -> {:halt, :error}
        end
      end)
    else
      :error
    end
  end

  defp interpolation_parts({kind, _, parts})
       when kind in [
              :bin_string,
              :list_string,
              :atom_safe,
              :atom_unsafe,
              :kw_identifier_safe,
              :kw_identifier_unsafe
            ],
       do: parts

  defp interpolation_parts({kind, _, _, parts}) when kind in [:bin_heredoc, :list_heredoc],
    do: parts

  defp interpolation_parts({:sigil, _, _, parts, _, _, _}), do: parts
  defp interpolation_parts(_), do: []
end
