defmodule MutagenEx.JsonStreamerTest do
  @moduledoc """
  Tests for `MutagenEx.JsonStreamer` — the NDJSON-per-site emitter
  introduced by bw mutagen-wrd.30.

  Subject advanced: `mutagen.json_schema.r10`.

  Each emitted line is a single JSON object terminated by `\\n`. The
  `kind` discriminator routes consumers between envelope events
  (`start`, `end`) and per-site events (`result`, `compile_error`).
  Per-site wire shape MUST be byte-equal to the equivalent entry in
  the aggregate document so consumers that aggregate the NDJSON
  stream produce the same `mutation.results[]` array the runner's
  aggregate emits.
  """

  use ExUnit.Case, async: true

  alias MutagenEx.JsonReporter
  alias MutagenEx.JsonReporter.Report
  alias MutagenEx.JsonStreamer
  alias MutagenEx.Mutators

  defp capture_sink(fun) do
    agent = start_supervised!({Agent, fn -> [] end}, id: make_ref())

    sink = fn iodata ->
      Agent.update(agent, fn acc -> [acc, iodata] end)
    end

    fun.(sink)

    Agent.get(agent, & &1) |> IO.iodata_to_binary()
  end

  defp parse_lines(text) do
    text
    |> String.split("\n", trim: true)
    |> Enum.map(&:json.decode/1)
  end

  describe "start envelope" do
    @describetag spec: "mutagen.json_schema.r14"

    @tag spec: "mutagen.json_schema.r15"
    test "emits version, kind=start, total, meta" do
      out =
        capture_sink(fn sink ->
          JsonStreamer.emit_start(sink, 42, %{
            tool_version: "0.1.0",
            elixir_version: "1.19.5",
            otp_version: "28",
            exunit_seed: 0
          })
        end)

      [decoded] = parse_lines(out)
      assert decoded["kind"] == "start"
      assert decoded["version"] == "2"
      assert decoded["meta"]["id_scheme"] == "2"
      assert decoded["total"] == 42
      assert decoded["meta"]["tool_version"] == "0.1.0"
      assert decoded["meta"]["elixir_version"] == "1.19.5"
      assert decoded["meta"]["otp_version"] == "28"
      assert decoded["meta"]["exunit_seed"] == 0
    end

    test "trailing newline is exactly one byte" do
      out =
        capture_sink(fn sink ->
          JsonStreamer.emit_start(sink, 0, %{})
        end)

      assert String.ends_with?(out, "\n")
      refute String.ends_with?(out, "\n\n")
    end
  end

  describe "result line" do
    @describetag spec: "mutagen.json_schema.r14"

    @tag spec: ["mutagen.json_schema.r4", "mutagen.mutators.r10"]
    test "every catalog mutator has the same confidence in aggregate results and NDJSON" do
      confidences = %{
        arith: :high,
        compare: :high,
        boolean: :high,
        literal: :high,
        with_swap: :low,
        case_drop: :high,
        pipeline: :high,
        result_tuple: :high,
        else_removal: :high,
        guard_drop: :high
      }

      assert Enum.sort(Map.keys(confidences)) == Enum.sort(Mutators.names())

      statuses = [:killed, :survived, :timeout, :error]

      results =
        for {mutator, confidence} <- confidences, {status, index} <- Enum.with_index(statuses) do
          assert Mutators.confidence(mutator) == confidence

          %{
            id: "lib/foo.ex:#{index}:#{mutator}",
            file: "lib/foo.ex",
            line: 1,
            column: 1,
            mutator: mutator,
            before: ":ok",
            before_source: ":ok",
            after: ":error",
            status: status
          }
        end

      {json, 0} = JsonReporter.emit_report(%Report{mutation: %{results: results}})
      aggregate = :json.decode(IO.iodata_to_binary(json))
      assert aggregate["version"] == "2"

      output =
        capture_sink(fn sink ->
          Enum.each(results, &JsonStreamer.emit_result(sink, &1))
        end)

      lines = parse_lines(output)
      entries = aggregate["mutation"]["results"]
      assert length(lines) == length(results)
      assert length(entries) == length(results)

      for {result, entry, line} <- Enum.zip([results, entries, lines]) do
        assert entry["mutator"] == Atom.to_string(result.mutator)
        assert entry["status"] == Atom.to_string(result.status)
        assert entry["confidence"] == Atom.to_string(Map.fetch!(confidences, result.mutator))
        assert line == Map.merge(entry, %{"kind" => "result", "version" => "2"})
      end
    end

    @tag spec: "mutagen.json_schema.r15"
    test "wire shape matches aggregate document's results[] entry" do
      result = %{
        id: "lib/foo.ex:abc:arith",
        file: "lib/foo.ex",
        line: 42,
        column: 13,
        mutator: :arith,
        original_ast: {:+, [], [1, 2]},
        mutated_ast: {:-, [], [1, 2]},
        status: :killed,
        tainted_predecessors: false,
        warnings: ["some warning"]
      }

      out = capture_sink(fn sink -> JsonStreamer.emit_result(sink, result) end)
      [decoded] = parse_lines(out)

      assert decoded["kind"] == "result"
      assert decoded["version"] == "2"
      assert decoded["id"] == "lib/foo.ex:abc:arith"
      assert decoded["file"] == "lib/foo.ex"
      assert decoded["line"] == 42
      assert decoded["column"] == 13
      assert decoded["mutator"] == "arith"
      assert decoded["status"] == "killed"
      assert decoded["tainted_predecessors"] == false
      assert decoded["warnings"] == ["some warning"]
      assert decoded["before"] == "1 + 2"
      assert decoded["before_source"] == "1 + 2"
      assert decoded["after"] == "1 - 2"
    end

    @tag spec: ["mutagen.json_schema.r4", "mutagen.json_schema.r14"]
    test "streamed results and aggregate entries have the same ID and enclosing function bytes" do
      for function <- ["Foo.bar/2", nil] do
        result = %{
          id: "lib/foo.ex:0123456789abcdef0123456789abcdef:arith",
          function: function,
          file: "lib/foo.ex",
          line: 1,
          column: 1,
          mutator: :arith,
          before: "a + b",
          before_source: "a  +  b",
          after: "a - b",
          status: :killed,
          warnings: []
        }

        {[doc, ?\n], 0} =
          MutagenEx.JsonReporter.emit_report(%Report{mutation: %{results: [result]}})

        [aggregate] = :json.decode(IO.iodata_to_binary(doc))["mutation"]["results"]
        [stream] = capture_sink(&JsonStreamer.emit_result(&1, result)) |> parse_lines()

        assert Map.fetch!(stream, "function") == (function || :null)
        assert :json.encode(Map.drop(stream, ["version", "kind"])) == :json.encode(aggregate)
      end
    end

    test "tainted_predecessors true round-trips" do
      result = %{
        id: "x",
        file: "lib/foo.ex",
        line: 1,
        column: 1,
        mutator: :arith,
        original_ast: 1,
        mutated_ast: 2,
        status: :survived,
        tainted_predecessors: true,
        warnings: []
      }

      out = capture_sink(fn sink -> JsonStreamer.emit_result(sink, result) end)
      [decoded] = parse_lines(out)
      assert decoded["tainted_predecessors"] == true
    end
  end

  describe "compile_error line" do
    @describetag spec: "mutagen.json_schema.r14"

    @tag spec: "mutagen.json_schema.r15"
    test "names id, file, line, column, mutator, message" do
      entry = %{
        id: "lib/foo.ex:bad:case_drop",
        file: "lib/foo.ex",
        line: 10,
        column: 5,
        mutator: :case_drop,
        message: "bad arity for case_drop"
      }

      out = capture_sink(fn sink -> JsonStreamer.emit_compile_error(sink, entry) end)
      [decoded] = parse_lines(out)

      assert decoded["kind"] == "compile_error"
      assert decoded["version"] == "2"
      assert decoded["id"] == "lib/foo.ex:bad:case_drop"
      assert decoded["mutator"] == "case_drop"
      assert decoded["diagnostic"] == "Elixir could not compile the mutated source."
      assert decoded["confidence"]
      refute Map.has_key?(decoded, "message")
      assert decoded["line"] == 10
    end
  end

  describe "end envelope" do
    @describetag spec: "mutagen.json_schema.r14"

    @tag spec: "mutagen.json_schema.r15"
    test "summarises killed/survived/timeout/compile_error/kill_rate from report.mutation" do
      report = %Report{
        meta: %{},
        mutation: %{
          total: 4,
          completed: 4,
          killed: 3,
          survived: 1,
          timeout: 0,
          compile_error: 0,
          kill_rate: 0.75
        },
        aborted: false,
        abort_reason: nil
      }

      out = capture_sink(fn sink -> JsonStreamer.emit_end(sink, report) end)
      [decoded] = parse_lines(out)

      assert decoded["kind"] == "end"
      assert decoded["version"] == "2"
      assert decoded["meta"]["id_scheme"] == "2"
      assert decoded["aborted"] == false
      assert decoded["abort_reason"] == :null
      assert decoded["killed"] == 3
      assert decoded["survived"] == 1
      assert decoded["kill_rate"] == 0.75
    end

    test "abort case carries abort_reason and resets counters when mutation never ran" do
      report = %Report{
        meta: %{},
        mutation: nil,
        aborted: true,
        abort_reason: "baseline_red"
      }

      out = capture_sink(fn sink -> JsonStreamer.emit_end(sink, report) end)
      [decoded] = parse_lines(out)

      assert decoded["aborted"] == true
      assert decoded["abort_reason"] == "baseline_red"
      assert decoded["killed"] == 0
      assert decoded["kill_rate"] in [nil, :null]
    end
  end

  describe "full stream is line-delimited JSON" do
    @describetag spec: "mutagen.json_schema.r14"

    test "concatenating start + result + result + end produces 4 valid JSON lines" do
      out =
        capture_sink(fn sink ->
          JsonStreamer.emit_start(sink, 2, %{exunit_seed: 0})

          JsonStreamer.emit_result(sink, %{
            id: "a",
            file: "lib/a.ex",
            line: 1,
            column: 1,
            mutator: :arith,
            original_ast: 1,
            mutated_ast: 2,
            status: :killed,
            tainted_predecessors: false,
            warnings: []
          })

          JsonStreamer.emit_result(sink, %{
            id: "b",
            file: "lib/b.ex",
            line: 2,
            column: 1,
            mutator: :arith,
            original_ast: 1,
            mutated_ast: 2,
            status: :survived,
            tainted_predecessors: false,
            warnings: []
          })

          JsonStreamer.emit_end(sink, %Report{
            meta: %{},
            mutation: %{
              total: 2,
              completed: 2,
              killed: 1,
              survived: 1,
              timeout: 0,
              compile_error: 0,
              kill_rate: 0.5
            },
            aborted: false,
            abort_reason: nil
          })
        end)

      lines = String.split(out, "\n", trim: true)
      assert length(lines) == 4

      decoded = Enum.map(lines, &:json.decode/1)
      assert Enum.map(decoded, & &1["kind"]) == ["start", "result", "result", "end"]

      # r10: every line carries "version". This is the regression gate —
      # if any line kind drops the discriminator, this assertion fails.
      assert Enum.all?(decoded, &(&1["version"] == "2"))
    end
  end
end
