defmodule MutagenEx.ReportProvenanceTest do
  use ExUnit.Case, async: false

  alias MutagenEx.{JsonReporter, Runtime, TestSelector}
  alias JsonReporter.{Report, Sanitizer}
  alias MutagenEx.JsonReporter.Provenance
  alias TestSelector.TestFilter

  @canary "ZZProvenanceFixture9"

  @tag spec: "mutagen.json_schema.r22"
  test "default details bound host atoms and count dynamically named tests and processes" do
    reason = String.to_atom(@canary)
    warnings = [{:host_process_died, @canary}, {:host_process_died, @canary}]
    failures = [{ExampleTest, "test generated #{@canary}"}, {ExampleTest, "test other"}]

    report = %Report{
      baseline: %{passed: 0, failed: 2, failures: failures},
      details: %{reason: reason, failures: failures},
      warnings: warnings
    }

    wire = abort(report)
    refute inspect(wire) =~ @canary
    assert wire["details"]["reason"] == "host_reason"
    expected = [%{"module" => "ExampleTest", "count" => 2}]
    assert wire["baseline"]["failures"] == expected
    assert wire["details"]["failures"] == expected
    assert wire["warnings"] == ["host_process_died: 1 registered process"]

    opted_in = abort(%{report | include_host_output: true})
    assert opted_in["details"]["reason"] == @canary
    assert Enum.any?(opted_in["baseline"]["failures"], &String.contains?(&1["name"], @canary))
    assert opted_in["warnings"] == ["host_process_died: #{@canary}"]

    assert JsonReporter.render_host_names(:persistent_terms, [{:fixture, @canary}], false) ==
             ["persistent_terms: 1"]

    assert [warning] =
             JsonReporter.render_host_names(:persistent_terms, [{:fixture, @canary}], true)

    assert warning =~ @canary

    assert abort(%Report{details: %{reason: :invalid_input}})["details"]["reason"] ==
             "invalid_input"
  end

  @tag spec: ["mutagen.json_schema.r22", "mutagen.mutation_pipeline.r7"]
  test "state leak warnings keep deltas and gate names on host output" do
    names = [
      processes: %{@canary => 1},
      ets: %{@canary => 2, :another => 3},
      persistent_term: %{{:fixture, @canary} => 1}
    ]

    warning = {:host_names, :state_leak, [{"site-id", names}]}
    report = %Report{warnings: [warning, warning]}

    assert [summary] = abort(report)["warnings"]
    assert summary =~ "state_leak after site site-id"
    assert summary =~ "processes: names=1, +1"
    assert summary =~ "ets: names=2, +5"
    assert summary =~ "persistent_term: names=1, +1"
    refute summary =~ @canary
    refute summary =~ "another"

    assert [details] = abort(%{report | include_host_output: true})["warnings"]
    assert details =~ "ets: :another +3"
    assert details =~ ~s("#{@canary}" +2)
    assert details =~ ~s({:fixture, "#{@canary}"} +1)
  end

  @tag spec: "mutagen.json_schema.r22"
  test "exception modules and locations require provenance" do
    module = Module.concat(Fixture, @canary)

    Module.create(
      module,
      quote(do: defexception(message: "synthetic")),
      Macro.Env.location(__ENV__)
    )

    on_exit(fn ->
      :code.delete(module)
      :code.purge(module)
    end)

    facts =
      Runtime.exception_facts(
        %CompileError{file: @canary, line: 42, description: "fake"},
        [{__MODULE__, :fixture, 0, [file: String.to_charlist(__ENV__.file), line: 12]}]
      )

    refute inspect(facts) =~ @canary
    assert facts.file == Path.relative_to_cwd(__ENV__.file)
    assert facts.line == 12

    assert Runtime.exception_facts(%Mix.Error{}, [
             {Mix, :raise, 1, [file: ~c"lib/mix.ex", line: 647]}
           ]) ==
             %{exception: Mix.Error}

    report = %Report{details: %{exception: module}}
    assert abort(report)["details"]["exception"] == "host exception"
    assert abort(%{report | include_host_output: true})["details"]["exception"] == inspect(module)
    assert abort(%Report{details: facts})["details"]["exception"] == "CompileError"
    assert Provenance.compiled_module?(MutagenEx.TestSelector)

    entry = %{
      id: "id",
      file: "lib/site.ex",
      line: 1,
      column: 1,
      mutator: :arith,
      exception: module,
      message: @canary
    }

    assert JsonReporter.compile_error_to_wire(entry)["exception"] == "host exception"
  end

  @tag spec: "mutagen.json_schema.r22"
  test "the report preserves CLI filters and reduces helper filters to verified tag keys" do
    cli = %TestFilter{include: [], exclude: [{:region, "cli"}], files: []}
    dynamic = String.to_atom("tag_" <> @canary)

    filters =
      TestSelector.merge_helper_filters(
        cli,
        [include: [], exclude: [{:region, @canary}, dynamic]],
        MapSet.new([:region])
      )

    report = %Report{
      tests: %{include: [], exclude: TestSelector.report_filters(filters, :exclude), files: []},
      details: %{exclude: TestSelector.report_filters(filters, :exclude)}
    }

    default = abort(report)

    for group <- ~w(tests details),
        do: assert(default[group]["exclude"] == ["region:cli", "region", "host tag"])

    assert filters.exclude == [{:region, "cli"}, {:region, @canary}, dynamic]
    assert inspect(abort(%{report | include_host_output: true})) =~ @canary
  end

  @tag spec: "mutagen.json_schema.r23"
  test "regex errors replace the field and the execution input is capped" do
    pattern = ~r/(*LIMIT_MATCH=1)(a+)+$/
    line = @canary <> " " <> String.duplicate("a", 2000) <> "!"
    assert Sanitizer.clean(line, patterns: [pattern]) == "[REDACTED: redaction failed]"
    line = String.duplicate("x", 65_536) <> @canary
    refute Sanitizer.clean(line, byte_size_limit: 100_000, patterns: []) =~ @canary
    assert Sanitizer.clean(line, byte_size_limit: 100_000, patterns: []) =~ "truncated"
  end

  @tag spec: "mutagen.json_schema.r23"
  test "truncation remains idempotent when redaction shrinks the bounded prefix" do
    prefix = String.duplicate("x", 4065)
    input = prefix <> " password: " <> String.duplicate("fake", 18_000)
    cleaned = Sanitizer.clean(input, patterns: [])
    assert byte_size(cleaned) > 4096
    assert cleaned == Sanitizer.clean(cleaned, patterns: [])
  end

  @tag spec: "mutagen.json_schema.r24"
  test "source keeps formatting whitespace and removes Unicode format characters" do
    assert Sanitizer.source("a\u202E\u2066\u200B\tb\nc") == "a\tb\nc"
  end

  @tag spec: "mutagen.json_schema.r22"
  test "a test filter struct keeps its cited file" do
    filter = %TestFilter{include: [], exclude: [], files: ["checks/cited_test.exs"]}
    assert abort(%Report{tests: filter})["tests"]["files"] == filter.files
  end

  @tag spec: ["mutagen.json_schema.r29", "mutagen.json_schema.r31", "mutagen.json_schema.r34"]
  test "automatic file paths are ordinary repository paths under the source flag" do
    path = "checks/#{@canary}_test.exs"

    report = %Report{
      meta: %{
        tests_selected: [%{path: path, why: :convention}],
        escalation: [%{step: :module, files_added: [path]}]
      },
      tests: %{include: [], exclude: [], files: [path], host_paths?: true},
      warnings: [{:escalation_rejected, :escalation_baseline_red, [path]}]
    }

    wire = abort(report)
    assert get_in(wire, ["meta", "tests_selected"]) == [%{"path" => path, "why" => "convention"}]
    assert get_in(wire, ["meta", "escalation", Access.at(0), "files_added"]) == [path]
    assert get_in(wire, ["tests", "files"]) == [path]
    assert wire["warnings"] == ["escalation_baseline_red: #{path}"]
    hidden = abort(%{report | include_host_output: true, source: false})
    assert hidden["warnings"] == ["escalation_baseline_red: 1"]
    refute inspect(hidden) =~ @canary
  end

  @tag spec: "mutagen.json_schema.r22"
  test "all default strings in a maximal aggregate and its stream have declared provenance" do
    file = "lib/site.ex"
    location = {:location, {file, 1}}

    site = %{
      id: "site-id",
      file: file,
      function: "Example.site/1",
      line: 1,
      column: 1,
      mutator: :arith,
      before: "a + 1",
      before_source: "a + 1",
      excerpt_line: 1,
      in_scope: :changed_group,
      selection: %{killed_at: :narrow, steps_run: [:narrow]},
      after: "a - 1",
      status: :killed,
      warnings: ["timeout"]
    }

    compile_error = Map.merge(site, %{exception: CompileError, message: @canary})
    failures = [{ExampleTest, "test generated #{@canary}"}]

    report = %Report{
      meta: %{
        tool_version: "test",
        elixir_version: "test",
        otp_version: "test",
        since: %{
          ref: "main",
          base: String.duplicate("b", 40),
          unmapped: [%{path: file, ranges: [[1, 1]], kind: :no_runtime_site}]
        },
        incomplete_reasons: [%{reason: :symlink, path: file}],
        tests_selected: [%{path: file, why: :convention}],
        escalation: [%{step: :module, files_added: [file]}],
        timings_ms: %{
          boot: 1,
          coverage: 2,
          baseline: 3,
          mutation: 4,
          total: 10,
          mutant_deadline: 5000
        }
      },
      scope: [%{file: file, line_range: 1..2, module: Example}],
      tests: %{include: [:cli, location], exclude: [:cli, location], files: [file]},
      coverage: %{covered_lines: %{file => [1]}},
      baseline: %{passed: 0, failed: 1, failures: failures},
      mutation: %{
        results: [site],
        pending: [Map.put(site, :reason, :uncovered)],
        compile_errors: [compile_error],
        skipped: [%{site_id: "id", file: file, reason: :validate_refused, mutator: :arith}],
        state_drift_warning: %{Example => [GenServer]}
      },
      warnings: ["test_alias_skipped"],
      details: %{
        file: file,
        origin_file: file,
        module: "Example",
        exception: RuntimeError,
        reason: :invalid_input,
        site_id: "id",
        phase: :coverage,
        cause: :invalid_ref,
        root: "lib",
        step: :coverage,
        flag: "--tests",
        failures: failures,
        include: [:cli, location],
        exclude: [:cli, location],
        message: @canary
      }
    }

    declared =
      ".spec/specs/json_schema.spec.md"
      |> File.read!()
      |> then(&Regex.scan(~r/^\| `([^`]+)` \| .+ \| .+ \|$/m, &1, capture: :all_but_first))
      |> List.flatten()
      |> MapSet.new()

    wire = abort(report)
    sink = fn body -> send(self(), {:wire_line, :json.decode(IO.iodata_to_binary(body))}) end
    streamer = MutagenEx.JsonStreamer
    streamer.emit_start(sink, 2, report.meta)
    streamer.emit_result(sink, site, report)
    streamer.emit_compile_error(sink, compile_error, report)
    streamer.emit_end(sink, %{report | aborted: true, abort_reason: "test_helper_load_failed"})

    stream_fields =
      Enum.flat_map(1..4, fn _ ->
        assert_received {:wire_line, line}

        case Map.pop(line, "kind") do
          {"result", entry} ->
            paths(Map.drop(entry, ["version"]), "mutation.results[]")

          {"compile_error", entry} ->
            paths(Map.drop(entry, ["version"]), "mutation.compile_errors[]")

          {_kind, envelope} ->
            paths(envelope, "")
        end
      end)

    assert MapSet.new(["kind" | paths(wire, "") ++ stream_fields]) == declared
  end

  defp paths(value, "mutation.results[].excerpt_line" = path) when is_integer(value), do: [path]
  defp paths(value, path) when is_binary(value), do: [path]
  defp paths(list, path) when is_list(list), do: Enum.flat_map(list, &paths(&1, path <> "[]"))

  defp paths(map, "meta.timings_ms") when is_map(map) do
    assert Map.keys(map) |> Enum.sort() ==
             ~w(baseline boot coverage mutant_deadline mutation total)

    assert Enum.all?(Map.values(map), &is_integer/1)
    ["meta.timings_ms"]
  end

  defp paths(map, path)
       when is_map(map) and path in ["coverage.covered_lines", "mutation.state_drift_warning"] do
    [path <> "{key}" | Enum.flat_map(Map.values(map), &paths(&1, path <> "{}"))]
  end

  defp paths(map, path) when is_map(map) do
    Enum.flat_map(map, fn {key, value} ->
      child = if path == "", do: key, else: path <> "." <> key
      paths(value, child)
    end)
  end

  defp paths(_value, _path), do: []

  defp abort(report) do
    {body, 2} = JsonReporter.emit_error(report, :test_helper_load_failed)
    body |> IO.iodata_to_binary() |> :json.decode()
  end
end
