defmodule MutagenEx.JsonReporter.Redactor do
  @moduledoc false

  @replacement "[REDACTED]"
  @words ~w(password passwd pgpassword pass pw pwd passphrase secret token
            apikey authorization cookie credentials dsn salt auth session webhook)
  @key_segments ~w(api private encryption signing access stripe)
  @query_words ~w(key sig signature credential securitytoken accesskey)
  @key_probe Regex.compile!(
               Enum.join(@words ++ @key_segments ++ @query_words ++ ["userinfo"], "|"),
               "i"
             )
  @key ~r/[a-z0-9][a-z0-9_-]*+/i

  # Match the key and separator only. The value scanner handles nested terms,
  # escaped strings and ambiguous bare values without regex backtracking.
  @pair Regex.compile!(
          ~S'''
          (?<![\w?&-])(?:~c|:)?(?:\\?["'])?(#{key})(?:\\?["'])?[^\S\r\n]*+(?:=>|===|==|=|:(?!//)|,)\s*
          '''
          |> String.trim()
          |> String.replace(~S(#{key}), @key.source),
          "i"
        )

  @userinfo ~r{(\b[a-z][a-z0-9+.-]*+://)[^/?#\s"'<>\\]*@[^/?#\s"'<>\\]*+}i
  @query ~r{([?&])([a-z0-9_-]++)(?:=)([^&#\s"'<>\\]*+)}i
  @pem ~r/-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----.*?(?:-----END [A-Z0-9 ]*PRIVATE KEY-----|\z)/s
  @tokens ~r"""

    \b(?:Bearer|Basic)[ \t]+[A-Za-z0-9._~+/=\-]{8,}
    |\beyJ[\w-]{8,}\.[\w-]{8,}\.[\w-]{8,}
    |\b(?:AKIA|ASIA)[A-Z0-9]{16}\b
    |\b(?:gh[pousr]_|github_pat_|glpat-|npm_|AIza|sk-|whsec_|[rs]k_(?:live|test)_|xox[abprs]-)[A-Za-z0-9_-]{8,}
    |\bSG\.[\w-]{8,}\.[\w-]{8,}
    |https://hooks\.slack\.com/services/[^\s"'<>\\]+
  """ix

  def compile(patterns) when is_list(patterns) do
    Enum.reduce_while(patterns, {:ok, []}, fn pattern, {:ok, acc} ->
      case compile_pattern(pattern) do
        {:ok, regex} -> {:cont, {:ok, [regex | acc]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      :error -> :error
    end
  end

  def compile(_), do: :error

  defp compile_pattern(%Regex{} = regex) do
    _ = Regex.match?(regex, "")
    {:ok, regex}
  rescue
    _ -> :error
  end

  defp compile_pattern(source) when is_binary(source) do
    case Regex.compile(source) do
      {:ok, regex} -> {:ok, regex}
      {:error, _} -> :error
    end
  end

  defp compile_pattern(_), do: :error

  def redact(message, patterns) do
    message
    |> then(
      &Regex.replace(@userinfo, &1, fn match, scheme ->
        case :binary.matches(match, "@") do
          [] ->
            match

          ats ->
            {last, 1} = List.last(ats)
            host = binary_part(match, last + 1, byte_size(match) - last - 1)
            scheme <> @replacement <> "@" <> host
        end
      end)
    )
    |> then(
      &Regex.replace(@query, &1, fn match, separator, key, _ ->
        if secret_key?(key) or Enum.any?(segments(key), fn part -> part in @query_words end),
          do: separator <> key <> "=" <> @replacement,
          else: match
      end)
    )
    |> then(&Regex.replace(@pem, &1, @replacement))
    |> then(&Regex.replace(@tokens, &1, @replacement))
    |> redact_pairs(0, 0, [])
    |> apply_patterns(patterns)
  end

  def apply_patterns(message, patterns) do
    Enum.reduce(patterns, message, &Regex.replace(&1, &2, @replacement))
  end

  def secret_key?(key) when is_binary(key) do
    if byte_size(key) >= 2 and Regex.match?(@key_probe, key) do
      parts = segments(key)

      Enum.any?(parts, &(&1 in @words)) or adjacent_key?(parts) or
        String.downcase(key, :ascii) in ["key", "sig", "signature", "access_key_id", "userinfo"]
    else
      false
    end
  end

  defp segments(key) do
    key
    |> then(&Regex.replace(~r/([A-Z])([A-Z][a-z])/, &1, "\\1_\\2"))
    |> then(&Regex.replace(~r/([a-z0-9])([A-Z])/, &1, "\\1_\\2"))
    |> String.downcase(:ascii)
    |> String.split(["_", "-"], trim: true)
  end

  defp adjacent_key?([prefix, "key" | _]) when prefix in @key_segments, do: true
  defp adjacent_key?([_ | rest]), do: adjacent_key?(rest)
  defp adjacent_key?([]), do: false

  defp redact_pairs(text, search, start, acc) do
    case Regex.run(@pair, text, offset: search, return: :index) do
      [{pos, size}, {key_pos, key_size}] ->
        key = binary_part(text, key_pos, key_size)
        prefix = binary_part(text, pos, size)
        value_at = pos + size
        value = binary_part(text, value_at, byte_size(text) - value_at)

        if credential_pair?(key, prefix, value) do
          rest = after_value(value)
          rest = if value_boundary?(rest), do: rest, else: after_line(rest)
          chunk = binary_part(text, start, value_at - start)
          next = byte_size(text) - byte_size(rest)
          redact_pairs(text, next, next, [@replacement, chunk | acc])
        else
          redact_pairs(text, value_at, start, acc)
        end

      nil ->
        tail = binary_part(text, start, byte_size(text) - start)
        IO.iodata_to_binary(Enum.reverse(acc, [tail]))
    end
  end

  defp credential_pair?(key, prefix, value) do
    (secret_key?(key) or (key == "authority" and String.starts_with?(value, "\""))) and
      not String.starts_with?(value, "//") and
      tuple_separator?(prefix)
  end

  # A comma separates a quoted key or an atom from a tuple's value.
  defp tuple_separator?(prefix) do
    not String.ends_with?(String.trim_trailing(prefix), ",") or
      String.starts_with?(prefix, [":", "\"", "'", "\\", "~c"])
  end

  defp value_boundary?(<<>>), do: true
  defp value_boundary?(<<c, _::binary>>) when c in [?", ?', ?}, ?], ?), ?,, ?\r, ?\n], do: true
  defp value_boundary?(<<92, quote, _::binary>>) when quote in [?", ?'], do: true
  defp value_boundary?(_), do: false

  defp after_value(<<"[REDACTED]", rest::binary>>), do: rest

  defp after_value(<<"~", sigil, rest::binary>>) when sigil in ~c"cCsS", do: after_value(rest)
  defp after_value(<<"\"\"\"", rest::binary>>), do: quoted(rest, "\"\"\"")
  defp after_value(<<"'''", rest::binary>>), do: quoted(rest, "'''")

  defp after_value(<<92, quote, rest::binary>>) when quote in [?", ?'],
    do: escaped_quote(rest, quote)

  defp after_value(<<quote, rest::binary>>) when quote in [?", ?'], do: quoted(rest, <<quote>>)
  defp after_value(<<"%{", rest::binary>>), do: balanced(rest, ["}"])
  defp after_value(<<"<<", rest::binary>>), do: balanced(rest, [">>"])

  defp after_value(<<open, rest::binary>>) when open in [?{, ?[, ?(],
    do: balanced(rest, [closer(open)])

  defp after_value(<<"%", _::binary>> = value) do
    case Regex.run(~r/\A%[a-zA-Z0-9_.]++\{/, value, return: :index) do
      [{0, size}] -> balanced(binary_part(value, size, byte_size(value) - size), ["}"])
      _ -> after_line(value)
    end
  end

  defp after_value(value), do: after_line(value)

  defp after_line(text) do
    case :binary.match(text, ["\r", "\n"]) do
      {at, _} -> binary_part(text, at, byte_size(text) - at)
      :nomatch -> ""
    end
  end

  defp quoted(text, delimiter) do
    size = byte_size(delimiter)

    case text do
      <<^delimiter::binary-size(size), rest::binary>> -> rest
      <<92, _, rest::binary>> -> quoted(rest, delimiter)
      <<_, rest::binary>> -> quoted(rest, delimiter)
      <<>> -> ""
    end
  end

  defp escaped_quote(<<92, 92, 92, quote, rest::binary>>, quote), do: escaped_quote(rest, quote)
  defp escaped_quote(<<92, quote, rest::binary>>, quote), do: rest
  defp escaped_quote(<<_, rest::binary>>, quote), do: escaped_quote(rest, quote)
  defp escaped_quote(<<>>, _quote), do: ""

  defp balanced(text, []), do: text
  defp balanced(<<>>, _stack), do: ""

  defp balanced(text, [close | stack] = pending) do
    size = byte_size(close)

    case text do
      <<^close::binary-size(size), rest::binary>> ->
        balanced(rest, stack)

      <<"<<", rest::binary>> ->
        balanced(rest, [">>" | pending])

      <<open, rest::binary>> when open in [?{, ?[, ?(] ->
        balanced(rest, [closer(open) | pending])

      <<quote, rest::binary>> when quote in [?", ?'] ->
        balanced(quoted(rest, <<quote>>), pending)

      <<92, quote, rest::binary>> when quote in [?", ?'] ->
        balanced(escaped_quote(rest, quote), pending)

      <<_, rest::binary>> ->
        balanced(rest, pending)
    end
  end

  defp closer(?{), do: "}"
  defp closer(?[), do: "]"
  defp closer(?(), do: ")"
end
