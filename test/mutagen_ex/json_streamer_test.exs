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

  alias MutagenEx.JsonReporter.Report
  alias MutagenEx.JsonStreamer

  defp capture_sink(fun) do
    agent = start_supervised!({Agent, fn -> [] end})

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
      assert decoded["version"] == "1"
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
      assert decoded["version"] == "1"
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
      assert decoded["version"] == "1"
      assert decoded["id"] == "lib/foo.ex:bad:case_drop"
      assert decoded["mutator"] == "case_drop"
      assert decoded["message"] == "bad arity for case_drop"
      assert decoded["line"] == 10
    end
  end

  describe "end envelope" do
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
      assert decoded["version"] == "1"
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
      assert Enum.all?(decoded, &(&1["version"] == "1"))
    end
  end
end
