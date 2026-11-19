defmodule MutagenEx.JsonReporter.Source do
  @moduledoc false

  # Keep literal positions in a separate tree so source extraction never changes
  # the AST used for mutation, coverage attribution, or site identity.
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
    options = [
      columns: true,
      token_metadata: true,
      emit_warnings: false,
      literal_encoder: &wrap_literal/2,
      preserve_comments: fn line, column, tokens, _, _ ->
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
    ]

    # Code.string_to_quoted/2 uses these same compiler entry points. We
    # also need the token boundaries to retain the spelling of literals.
    with {:ok, tokens} <-
           :elixir.string_to_tokens(String.to_charlist(source), 1, 1, file, options),
         {:ok, ast} <- :elixir.tokens_to_quoted(tokens, file, options) do
      offsets = byte_offsets(source)
      ranges = token_ranges(tokens, byte_size(source), source, offsets, Process.get(key), %{})
      {ast, ranges}
    else
      _ -> nil
    end
  end

  defp wrap_literal(value, metadata),
    do: {:ok, {:__block__, [{:mutagen_literal, true} | metadata], [value]}}

  def span({ast, ranges}, path) do
    with node when not is_nil(node) <- at_path(ast, path),
         {start, _} <- Map.get(ranges, start_position(node)),
         {_, stop} <- Map.get(ranges, last_token(node)),
         true <- start < stop do
      {start, stop - start}
    else
      _ -> nil
    end
  end

  def span(nil, _path), do: nil

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

  defp token_ranges(tokens, stop, source, offsets, comments, ranges) do
    Enum.reduce(Enum.reverse(tokens), {stop, ranges}, fn token, {stop, ranges} ->
      pos = token_position(token)
      start = Map.fetch!(offsets, pos)
      limit = Map.get(offsets, Map.get(comments, pos), stop) |> min(stop)

      ranges =
        if start < limit do
          text = binary_part(source, start, limit - start)
          Map.put(ranges, pos, {start, start + byte_size(String.trim_trailing(text))})
        else
          ranges
        end

      ranges =
        for {_open, {line, column, _}, inner} <- interpolation_parts(token), reduce: ranges do
          acc ->
            stop = Map.fetch!(offsets, {line, column})
            token_ranges(inner, stop, source, offsets, comments, acc)
        end

      {start, ranges}
    end)
    |> elem(1)
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
