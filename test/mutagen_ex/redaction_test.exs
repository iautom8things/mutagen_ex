defmodule MutagenEx.RedactionTest do
  use ExUnit.Case, async: false

  alias MutagenEx.{JsonReporter, JsonStreamer}
  alias JsonReporter.{Report, Sanitizer}

  @tag spec: "mutagen.json_schema.r17"
  test "redacts inspected key/value credentials, URLs, query parameters, and tokens by default" do
    for {message, secrets} <- [
          {~s(opts [password: "db-password", url: "ecto://admin:url-password@db/prod", api_key: "key-value"]),
           ~w(db-password url-password key-value)},
          {~s(cannot reach ecto://user:bad-password@db?token=query-secret&ok=1),
           ~w(bad-password query-secret)},
          {~s(%{"token" => "map-token", :secret_key_base => "map-secret", private_key: "long\\nkey"}),
           ~w(map-token map-secret long)},
          {~s(invalid URL ecto://admin:duplicate@db, parsed: %URI{authority: "admin:duplicate@db", userinfo: "admin:duplicate"}),
           ["duplicate"]},
          {"authorization=Bearer bearer-secret github_pat_abcdefghijklmnop",
           ~w(bearer-secret github_pat_abcdefghijklmnop)}
        ] do
      cleaned = Sanitizer.clean(message)
      assert cleaned =~ "[REDACTED]"
      refute Enum.any?(secrets, &String.contains?(cleaned, &1)), cleaned
      assert Sanitizer.clean(cleaned) == cleaned
    end
  end

  @tag spec: "mutagen.json_schema.r17"
  test "redacts compound credential keys in keyword, map, env and query shapes" do
    for key <- ~w(DATABASE_PASSWORD db_password api-token secret_key_base AWS_SECRET_ACCESS_KEY) do
      for message <- [
            inspect([{String.to_atom(key), "kw-value"}, pool: 10]),
            inspect(%{key => "map-value"}),
            "#{key}=env-value ./start",
            "https://example.test/cb?#{key}=query-value&ok=1"
          ] do
        cleaned = Sanitizer.clean(message)
        assert cleaned =~ "[REDACTED]", cleaned
        refute cleaned =~ ~r/(kw|map|env|query)-value/, cleaned
        assert Sanitizer.clean(cleaned) == cleaned
      end
    end

    assert Sanitizer.clean("tokenizer: 3, secretary: ann, primary_key: 7") ==
             "tokenizer: 3, secretary: ann, primary_key: 7"

    report = %Report{
      include_host_output: true,
      details: %{database_password: "detail-value"},
      tests: %{include: [], exclude: ["api-token": "filter-value"], files: []}
    }

    {data, _code} = JsonReporter.emit_error(report, :host_app_start_failed)
    decoded = data |> IO.iodata_to_binary() |> :json.decode()
    assert decoded["details"]["database_password"] == "[REDACTED]"
    assert decoded["tests"]["exclude"] == ["api-token:[REDACTED]"]
  end

  @tag spec: ["mutagen.json_schema.r11", "mutagen.json_schema.r17"]
  test "built-in redaction precedes configured patterns and truncation" do
    assert Sanitizer.clean(~s(password="hunter2", custom example),
             patterns: ["custom"],
             byte_size_limit: 40
           ) ==
             "password=[REDACTED], [REDACTED] example"

    assert Sanitizer.clean("token=password123\nraw diagnostics") ==
             "token=[REDACTED]\nraw diagnostics"
  end

  @tag spec: "mutagen.json_schema.r17"
  test "sanitizes report details, baseline failures, filters, and streamed warnings" do
    secret = "fixture-sensitive-string"
    warning = "password: #{secret}"

    result = %{
      id: "one",
      file: "lib/a.ex",
      line: 1,
      column: 1,
      mutator: :arith,
      before: "1",
      before_source: "1",
      after: "2",
      status: :killed,
      warnings: [warning]
    }

    compile_error = Map.put(result, :message, warning)

    report = %Report{
      include_host_output: true,
      warnings: [warning],
      details: %{password: secret, nested: [%{message: warning}]},
      tests: %{include: [], exclude: [foo: [:a], token: secret], files: []},
      baseline: %{
        "passed" => 0,
        "failed" => 1,
        "failures" => [%{"module" => "Example", "name" => warning}]
      },
      mutation: %{results: [result], compile_errors: [compile_error]}
    }

    {data, 2} = JsonReporter.emit_error(report, :baseline_red)
    json = IO.iodata_to_binary(data)
    refute json =~ secret
    decoded = :json.decode(json)
    assert decoded["details"]["password"] == "[REDACTED]"
    assert decoded["tests"]["exclude"] == ["foo:[:a]", "token:[REDACTED]"]
    assert decoded["baseline"]["failures"] |> hd() |> Map.fetch!("name") =~ "[REDACTED]"

    sink = fn iodata -> send(self(), {:line, IO.iodata_to_binary(iodata)}) end
    JsonStreamer.emit_result(sink, result, report)
    JsonStreamer.emit_compile_error(sink, compile_error, report)
    assert_received {:line, result_line}
    assert_received {:line, error_line}
    refute result_line =~ secret
    refute error_line =~ secret
    assert :json.decode(result_line)["warnings"] == ["password: [REDACTED]"]
    assert :json.decode(error_line)["message"] == "password: [REDACTED]"
  end
end
