defmodule MutagenEx.ReportSafetyTest do
  use ExUnit.Case, async: true

  alias MutagenEx.{CLI, JsonReporter, JsonStreamer}
  alias JsonReporter.{Redactor, Report, Sanitizer}

  @tag spec: "mutagen.cli.r24"
  test "host text and source switches are independent" do
    args = ~w(--scope Foo --tests test/foo_test.exs)
    assert {:ok, %{source: true, include_host_output: false}} = CLI.parse(args)

    assert {:ok, %{source: false, include_host_output: true}} =
             CLI.parse(args ++ ~w(--no-source --include-host-output))
  end

  @tag spec: "mutagen.json_schema.r18"
  test "aggregate and stream cap source, remove control bytes and omit source on request" do
    example =
      "ecto://user:fake-source-credential@host/" <> <<0, 27>> <> String.duplicate("z", 4200)

    result = site(%{before: example, before_source: example, after: example})
    error = site(%{message: "fake compile-time secret", exception: CompileError})

    for source <- [true, false] do
      options = %Report{source: source, mutation: %{results: [result], compile_errors: [error]}}
      {data, 0} = JsonReporter.emit_report(options)
      mutation = decode(data)["mutation"]
      [wire] = mutation["results"]
      [compile_error] = mutation["compile_errors"]
      assert wire == streamed(&JsonStreamer.emit_result/3, result, options)
      assert compile_error == streamed(&JsonStreamer.emit_compile_error/3, error, options)
      assert wire["confidence"] == "high"
      assert compile_error["confidence"] == "high"
      assert compile_error["exception"] == "CompileError"
      refute Map.has_key?(compile_error, "message")

      if source do
        assert wire["file"] == "lib/calculator.ex"
        assert compile_error["function"] == "Calculator.add/2"
        assert compile_error["diagnostic"]

        for key <- ~w(before before_source after) do
          assert wire[key] =~ "fake-source-credential"
          refute wire[key] =~ <<0>>
          refute wire[key] =~ <<27>>

          assert String.ends_with?(
                   wire[key],
                   "<#{byte_size(example) - 2 - 4096} bytes truncated>"
                 )
        end
      else
        assert Map.take(wire, ~w(before before_source after file function)) == %{}
        assert Map.take(compile_error, ~w(file function diagnostic)) == %{}
      end
    end
  end

  @tag spec: ["mutagen.json_schema.r10", "mutagen.json_schema.r19"]
  test "host strings are opt-in and dropped bytes are counted once per wire field" do
    warning = String.duplicate("x", 10_400)
    result = site(%{warnings: [{:host_output, warning}]})
    error = site(%{message: warning})

    report = %Report{
      details: %{
        message: warning,
        step: :test_helper,
        exception: RuntimeError,
        file: "test/test_helper.exs",
        line: 3
      },
      warnings: [{:host_output, warning}],
      mutation: %{results: [result], compile_errors: [error]}
    }

    {data, 2} = JsonReporter.emit_error(report, :test_helper_load_failed)
    default = decode(data)
    assert default["warnings"] == []
    assert hd(default["mutation"]["results"])["warnings"] == []
    refute Map.has_key?(hd(default["mutation"]["compile_errors"]), "message")

    assert %{
             "step" => "test_helper",
             "exception" => "RuntimeError",
             "file" => "test/test_helper.exs",
             "line" => 3,
             "hint" => "Check the test helper at the reported location."
           } = default["details"]

    refute Map.has_key?(default["details"], "message")

    options = %{report | include_host_output: true}
    {data, 2} = JsonReporter.emit_error(options, :test_helper_load_failed)
    opted_in = decode(data)
    [wire] = opted_in["mutation"]["results"]
    [compile_error] = opted_in["mutation"]["compile_errors"]
    assert wire == streamed(&JsonStreamer.emit_result/3, result, options)
    assert compile_error == streamed(&JsonStreamer.emit_compile_error/3, error, options)

    truncated = String.duplicate("x", 4096) <> " ... <6304 bytes truncated>"
    assert Sanitizer.clean(truncated) == truncated
    assert opted_in["warnings"] == [truncated]
    assert wire["warnings"] == [truncated]
    assert compile_error["message"] == truncated
    assert opted_in["details"]["message"] == truncated
  end

  @tag spec: "mutagen.json_schema.r17"
  test "redacts credential shapes before truncation" do
    fake = "ZZFixtureFakeValue"
    jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJmaXh0dXJlIn0.fakeFixtureSignature"

    values = [
      "redis://:#{fake}@cache/0",
      "root:#{fake}@cache:5432/db",
      "--password #{fake}",
      "password(#{fake})",
      "secrets: #{fake}",
      "passwords: [~c\"#{fake}\"]",
      "tokens: %{value: #{fake}}",
      "https://#{fake}@git.example/repo",
      "postgres://root:one@two@#{fake}@db/path",
      ~s(%URI{authority: "root:#{fake}@db", userinfo: "root:#{fake}"}),
      ~s({:password, "#{fake}"}),
      ~s(token: %{value: ["a", %{b: "#{fake}"}]}),
      inspect(~s({"clientSecret":"#{fake}","accessToken":"#{fake}"})),
      inspect(~s(password: "#{fake}")),
      "password=prefix,#{fake}",
      "password=prefix&#{fake}",
      "password=prefix}#{fake}",
      "password=prefix with spaces #{fake}",
      "password: [REDACTED] #{fake}",
      ~s(password: "#{fake}" trailing unstructured text),
      "password: [REDACTED],token=#{fake}",
      "password=[REDACTED]&#{fake}",
      "password: \"\"\"\n#{fake}\n\"\"\"",
      "password: ~s(#{fake})",
      "password:\n  #{fake}",
      "authorization failed with Bearer #{fake}",
      "credentials carried Basic #{fake}",
      "-----BEGIN RSA PRIVATE KEY-----\n#{fake}\n-----END RSA PRIVATE KEY-----",
      "-----BEGIN PRIVATE KEY-----\n#{fake}",
      "https://hooks.slack.com/services/T00000000/B00000000/#{fake}",
      jwt,
      "AKIAIOSFODNN7EXAMPLE",
      "ASIAIOSFODNN7EXAMPLE",
      "SG.#{fake}.#{fake}"
    ]

    values =
      values ++
        for key <-
              ~w(key sig signature token X-Amz-Signature X-Amz-Credential X-Amz-Security-Token) do
          "https://example.test/a?#{key}=#{fake}&ok=1"
        end

    values =
      values ++
        for key <- ~w(authorization proxy-authorization cookie set-cookie x-api-key),
            format <- [
              fn k -> ~s({"#{k}", "#{fake}"}) end,
              fn k -> ~s("#{k}": "#{fake}") end,
              fn k -> ~s({~c"#{k}", ~c"#{fake}"}) end
            ] do
          format.(key)
        end

    values =
      values ++
        for key <-
              ~w(clientSecret accessToken dbPassword PGPASSWORD pass pwd
                                       passphrase salt signing_salt credentials dsn encryptionKey signing-key) do
          "#{key}=#{fake}"
        end

    values =
      values ++
        for prefix <- ~w(ghp_ gho_ github_pat_ glpat- npm_ AIza sk- sk-ant- whsec_
                                        sk_live_ sk_test_ xoxa- xoxb- xoxp-) do
          prefix <> fake
        end

    for text <- values do
      cleaned = Redactor.redact(text, [])
      assert Sanitizer.clean(text, patterns: []) == cleaned
      assert cleaned =~ "[REDACTED]", text
      refute cleaned =~ fake, text
      refute cleaned == text
      assert Sanitizer.clean(cleaned, patterns: []) == cleaned
    end

    assert Sanitizer.clean(~s(password: ~c"#{fake}")) == "password: [REDACTED]"
    assert Sanitizer.clean("password: [104, 117, 110, 0], ok: 1") == "password: [REDACTED], ok: 1"

    assert Sanitizer.clean("password: <<104, 117, 110, 0>>, ok: 1") ==
             "password: [REDACTED], ok: 1"

    assert Sanitizer.clean("https://user:one@two@db/path?sig=fake&ok=1") ==
             "https://[REDACTED]@db/path?sig=[REDACTED]&ok=1"
  end

  @tag spec: ["mutagen.json_schema.r17", "mutagen.json_schema.r32"]
  @tag timeout: to_timeout(minute: 1)
  test "redaction handles a megabyte of adversarial text without stalling" do
    for line <- [
          String.duplicate("eyJaaaaaaaa-", 87_382),
          String.duplicate("a.", 524_288) <> " postgres://root:ZZTailFixture@db/path",
          String.duplicate("a://b:", 174_763),
          "password: \"" <> String.duplicate("a\\", 524_288),
          String.duplicate("a_", 524_288) <> "token=fixture"
        ] do
      control = binary_part(line, 0, 32 * 1024)
      sample = fn input -> :timer.tc(fn -> Sanitizer.clean(input, patterns: []) end) end
      sample.(control)
      {before, _} = sample.(control)
      {elapsed, cleaned} = sample.(line)
      {after_, _} = sample.(control)
      assert elapsed < 8 * max(before, after_)
      assert byte_size(cleaned) <= 4136
    end
  end

  defmodule AbortCoverage do
    def run(_),
      do: {:error, Process.get(:fixture_abort_reason), %{message: "ZZAbortCanaryFromHost"}}
  end

  defmodule WriteWithoutHalt do
    def emit(data, 2, config), do: MutagenEx.Pipeline.DefaultIo.write(data, config)
  end

  @tag :tmp_dir
  @tag spec: ["mutagen.json_schema.r20", "mutagen.cli.r26"]
  test "the docs cover the registered abort reasons and each abort uses the selected sink", %{
    tmp_dir: dir
  } do
    declared = JsonReporter.abort_reasons() |> Enum.sort()
    assert "diff_unavailable" in declared
    assert "invalid_since_ref" in declared
    assert "escalation_crashed" in declared

    for path <- ["README.md", ".spec/specs/json_schema.spec.md"] do
      [_, section] =
        path |> File.read!() |> String.split(~r/\n[#]{2,3} Abort reasons\n/, parts: 2)

      table = section |> String.split(~r/\n[#]{2,3} /, parts: 2) |> hd()

      rows =
        Regex.scan(~r/^\| `(?!abort_reason`)([a-z0-9_]+)` \|/m, table, capture: :all_but_first)

      assert rows |> List.flatten() |> Enum.sort() == declared
    end

    refute Mix.Tasks.Mutagen |> Code.fetch_docs() |> elem(4) |> Map.fetch!("en") =~ ~r/`reason: :/

    scope = "test/fixtures/lane_project/lib/lane_fixture/arith.ex"
    cited = "test/fixtures/lane_project/test/lane_fixture/arith_test.exs"
    args = ["--scope", scope, "--tests", cited, "--json", "error.json"]
    dispatch = %{coverage: AbortCoverage, io: WriteWithoutHalt, project_root: dir}

    assert {:aborted, :missing_scope, _} =
             Mix.Tasks.Mutagen.run(~w(--tests) ++ [cited] ++ ~w(--json error.json), dispatch)

    path = Path.join(dir, "error.json")
    assert :json.decode(File.read!(path))["abort_reason"] == "missing_scope"

    for name <- declared do
      reason = String.to_atom(name)
      Process.put(:fixture_abort_reason, reason)
      assert {:aborted, ^reason, _} = Mix.Tasks.Mutagen.run(args, dispatch)

      report = :json.decode(File.read!(path))
      assert report["abort_reason"] == name
      assert report["details"]["hint"] != ""
      refute Map.has_key?(report["details"], "message")
      refute File.read!(path) =~ "ZZAbortCanaryFromHost"
    end
  end

  @tag spec: "mutagen.json_schema.r33"
  test "every registered abort overrides a complete changed-code report" do
    report = %Report{meta: %{since: %{}, incomplete_reasons: []}}

    for name <- JsonReporter.abort_reasons() do
      {output, 2} = JsonReporter.emit_error(report, String.to_atom(name))
      wire = output |> IO.iodata_to_binary() |> JSON.decode!()
      assert wire["aborted"]
      assert wire["abort_reason"] == name
      assert wire["meta"]["complete"] == false
    end
  end

  @tag spec: "mutagen.json_schema.r20"
  test "a pipeline abort from a variable must use a registered reason" do
    reason = :unregistered_fixture_reason
    Process.put(:fixture_abort_reason, reason)

    assert_raise ArgumentError, "unknown Mutagen abort reason: unregistered_fixture_reason", fn ->
      Mix.Tasks.Mutagen.run(
        ~w(--scope test/fixtures/lane_project/lib/lane_fixture/arith.ex
           --tests test/fixtures/lane_project/test/lane_fixture/arith_test.exs),
        %{coverage: AbortCoverage, io: WriteWithoutHalt}
      )
    end

    assert_raise ArgumentError, "unknown Mutagen abort reason: unregistered_fixture_reason", fn ->
      JsonStreamer.emit_end(fn _ -> flunk("unexpected stream output") end, %Report{
        aborted: true,
        abort_reason: Atom.to_string(reason)
      })
    end
  end

  test "published docs use the anonymized set name and describe supervised work" do
    readme = File.read!("README.md")
    refute readme =~ ~r/\bmutagen-[a-z0-9]{3}\b/
    assert readme =~ "a pre-release commit of this series"

    [_, limits] = String.split(readme, "## Known limitations\n", parts: 2)
    limits = limits |> String.split("\n## ", parts: 2) |> hd()
    assert limits =~ "Task.Supervisor.async_nolink/2"
    assert limits =~ "DynamicSupervisor.start_child/2"
    assert limits =~ "can outlive the timeout"

    [header | rows] =
      "docs/precision/blind-2026-11.csv" |> File.read!() |> String.split("\n", trim: true)

    assert header == "set,class,mutator,confidence,verdict,basis"
    assert rows != []
    assert Enum.all?(rows, &String.starts_with?(&1, "blind-2026-11,"))
  end

  defp site(fields) do
    Map.merge(
      %{
        id: "lib/calculator.ex:id:arith",
        file: "lib/calculator.ex",
        function: "Calculator.add/2",
        line: 4,
        column: 5,
        mutator: :arith,
        status: :killed,
        before: "x + y",
        before_source: "x + y",
        after: "x - y"
      },
      fields
    )
  end

  defp streamed(emit, item, options) do
    sink = fn data -> send(self(), {:line, decode(data)}) end
    assert :ok = emit.(sink, item, options)
    assert_received {:line, line}
    Map.drop(line, ~w(kind version))
  end

  defp decode(data), do: data |> IO.iodata_to_binary() |> :json.decode()
end
