defmodule MutagenEx.JsonReporter.Redactor do
  @moduledoc false

  @replacement "[REDACTED]"
  @failure "[REDACTED: redaction failed]"
  @input_limit 64 * 1024
  @words ~w(password passwd pgpassword pass pw pwd passphrase secret secrets password passwords token tokens
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

  @userinfo ~r{((?<![a-z0-9+.-])[a-z][a-z0-9+.-]*+://)[^/?#\s"'<>\\]*@[^/?#\s"'<>\\]*+}i
  @schemeless ~r{(?<![\w.+:/-])[\w.%+-]++:[^/?#\s"'<>\\]*@(?=[a-z0-9])}i
  @shorthand ~r{(?<![\w-])(?:--(?:password|passwd|passphrase|token|secret)[ \t]++|(?:password|passwd|passphrase|token|secret)(?=\())}i
  @query ~r{([?&])([a-z0-9_-]++)(?:=)([^&#\s"'<>\\]*+)}i
  @pem ~r/-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----.*?(?:-----END [A-Z0-9 ]*PRIVATE KEY-----|\z)/s
  @tokens ~r"""

    \b(?:Bearer|Basic)[ \t]+[A-Za-z0-9._~+/=\-]{8,}
    |(?<![\w-])eyJ[\w-]{8,}\.[\w-]{8,}\.[\w-]{8,}
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

  def input_limit, do: @input_limit
  def failure, do: @failure

  def redact(message, patterns) do
    message
    |> bounded()
    |> then(
      &replace(@userinfo, &1, fn [match, scheme] ->
        ats = :binary.matches(match, "@")
        {last, 1} = List.last(ats)
        host = binary_part(match, last + 1, byte_size(match) - last - 1)
        scheme <> @replacement <> "@" <> host
      end)
    )
    |> then(&replace(@schemeless, &1, @replacement <> "@"))
    |> then(
      &replace(@query, &1, fn [match, separator, key, _] ->
        if credential_key?(key) or Enum.any?(segments(key), fn part -> part in @query_words end),
          do: separator <> key <> "=" <> @replacement,
          else: match
      end)
    )
    |> then(&replace(@pem, &1, @replacement))
    |> then(&replace(@tokens, &1, @replacement))
    |> redact_pairs(@shorthand, 0, 0, [])
    |> redact_pairs(@pair, 0, 0, [])
    |> replace_patterns(patterns)
  catch
    :redaction_failed -> @failure
  end

  def apply_patterns(message, patterns) do
    message |> bounded() |> replace_patterns(patterns)
  catch
    :redaction_failed -> @failure
  end

  defp replace_patterns(message, patterns) do
    Enum.reduce(patterns, message, &replace(&1, &2, @replacement))
  end

  defp bounded(message), do: binary_part(message, 0, min(byte_size(message), @input_limit))

  def secret_key?(key) when is_binary(key) do
    credential_key?(bounded(key))
  catch
    :redaction_failed -> true
  end

  defp credential_key?(key) do
    if byte_size(key) >= 2 and run(@key_probe, key, capture: :none) == :match do
      parts = segments(key)

      Enum.any?(parts, &(&1 in @words)) or adjacent_key?(parts) or
        String.downcase(key, :ascii) in ["key", "sig", "signature", "access_key_id", "userinfo"]
    else
      false
    end
  end

  defp segments(key) do
    key
    |> then(&replace(~r/([A-Z])([A-Z][a-z])/, &1, fn [_, a, b] -> [a, "_", b] end))
    |> then(&replace(~r/([a-z0-9])([A-Z])/, &1, fn [_, a, b] -> [a, "_", b] end))
    |> String.downcase(:ascii)
    |> String.split(["_", "-"], trim: true)
  end

  defp run(regex, text, opts) do
    case :re.run(text, Regex.re_pattern(regex), [:report_errors | opts]) do
      {:error, _} -> throw(:redaction_failed)
      result -> result
    end
  rescue
    ArgumentError -> throw(:redaction_failed)
  end

  defp replace(regex, text, replacement) do
    capture = if is_function(replacement), do: :all, else: :first

    case run(regex, text, [:global, {:capture, capture, :index}]) do
      :nomatch -> text
      {:match, matches} -> assemble(text, matches, replacement, 0, []) |> IO.iodata_to_binary()
    end
  end

  defp assemble(text, [[{at, size} | _] = captures | rest], replacement, offset, acc) do
    value =
      if is_function(replacement),
        do: replacement.(Enum.map(captures, &slice(text, &1))),
        else: replacement

    assemble(text, rest, replacement, at + size, [
      value,
      binary_part(text, offset, at - offset) | acc
    ])
  end

  defp assemble(text, [], _replacement, offset, acc) do
    Enum.reverse(acc, [binary_part(text, offset, byte_size(text) - offset)])
  end

  defp slice(_text, {-1, 0}), do: ""
  defp slice(text, {at, size}), do: binary_part(text, at, size)

  defp adjacent_key?([prefix, "key" | _]) when prefix in @key_segments, do: true
  defp adjacent_key?([_ | rest]), do: adjacent_key?(rest)
  defp adjacent_key?([]), do: false

  defp redact_pairs(text, pattern, search, start, acc) do
    case run(pattern, text, [{:offset, search}, {:capture, :all, :index}]) do
      {:match, [{pos, size} | captures]} ->
        prefix = binary_part(text, pos, size)
        value_at = pos + size
        value = binary_part(text, value_at, byte_size(text) - value_at)

        if captures == [] or credential_pair?(slice(text, hd(captures)), prefix, value) do
          rest = after_value(value)
          rest = if value_boundary?(rest), do: rest, else: after_line(rest)
          chunk = binary_part(text, start, value_at - start)
          next = byte_size(text) - byte_size(rest)
          redact_pairs(text, pattern, next, next, [@replacement, chunk | acc])
        else
          redact_pairs(text, pattern, value_at, start, acc)
        end

      :nomatch ->
        tail = binary_part(text, start, byte_size(text) - start)
        IO.iodata_to_binary(Enum.reverse(acc, [tail]))
    end
  end

  defp credential_pair?(key, prefix, value) do
    (credential_key?(key) or (key == "authority" and String.starts_with?(value, "\""))) and
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
    case run(~r/\A%[a-zA-Z0-9_.]++\{/, value, []) do
      {:match, [{0, size}]} -> balanced(binary_part(value, size, byte_size(value) - size), ["}"])
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
