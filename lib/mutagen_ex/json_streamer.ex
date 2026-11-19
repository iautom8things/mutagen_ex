defmodule MutagenEx.JsonStreamer do
  @moduledoc """
  Per-site NDJSON line emitter for `mix mutagen --stream`.

  Contract: [`mutagen.json_schema`](../../.spec/specs/json_schema.spec.md)
  r14 (NDJSON line shape, byte-equal to the equivalent entry in the
  final aggregate document's `mutation.results` / `mutation.compile_errors`).

  Each line is a JSON object terminated by a single `\\n`. The wire
  shape mirrors what `MutagenEx.JsonReporter` emits inside the final
  document — that is, the same map keys and value encodings, plus a
  `kind` discriminator (`"result"` or `"compile_error"`) and the same
  `version` literal the aggregate uses. Consumers parsing line-by-line
  can route on `kind`:

      {"version":"2","kind":"start","total":42,"meta":{...}}
      {"version":"2","kind":"result","id":"...","status":"killed","confidence":"high",...}
      {"version":"2","kind":"compile_error","id":"...","message":"..."}
      {"version":"2","kind":"end","meta":{"id_scheme":"2",...},"aborted":false,"abort_reason":null,
       "kill_rate":0.81,...}

  `start` and `end` envelope lines bracket the run. Per-site `result`
  and `compile_error` lines are emitted in **input order** — the
  runner streams them through `:on_site_completed` AS the
  per-input-index task completes (via the `async_stream`'s ordered
  collection guarantee), which means the byte-identical-output gate
  holds for the concatenated NDJSON stream too.
  """

  alias MutagenEx.JsonReporter
  alias MutagenEx.JsonReporter.Report

  @typedoc "I/O sink. Any iolist-accepting function or a device."
  @type sink :: (iodata() -> any()) | IO.device()

  @doc """
  Emit the `start` envelope line. Returns `:ok`.

  `total` is the total site count the runner will attempt; `meta` is
  the same `meta` block the final document carries (tool version,
  Elixir/OTP version, ExUnit seed, and fail-fast setting).
  """
  @spec emit_start(sink(), pos_integer() | non_neg_integer(), map()) :: :ok
  def emit_start(sink, total, meta) do
    write_line(sink, %{
      "version" => JsonReporter.schema_version(),
      "kind" => "start",
      "total" => total,
      "meta" => JsonReporter.meta_to_wire(meta)
    })
  end

  @doc """
  Emit a per-site `result` line (`status` ∈ killed/survived/timeout/error).

  Accepts a rendered result or the raw result from the runner.
  """
  @spec emit_result(sink(), map()) :: :ok
  def emit_result(sink, %{} = result_map) do
    result_map
    |> render_result()
    |> JsonReporter.result_to_wire()
    |> Map.merge(%{"version" => JsonReporter.schema_version(), "kind" => "result"})
    |> then(&write_line(sink, &1))
  end

  @doc """
  Emit a per-site `compile_error` line.
  """
  @spec emit_compile_error(sink(), map()) :: :ok
  def emit_compile_error(sink, %{} = entry) do
    write_line(sink, Map.put(compile_error_to_wire(entry), "kind", "compile_error"))
  end

  @doc """
  Emit the `end` envelope line.

  `report` is the final `%Report{}` the pipeline assembled. The line
  carries report metadata, including the ID scheme, and the counters (`total`, `killed`, `survived`,
  `timeout`, `compile_error`, `kill_rate`) AND the abort fields, so a
  consumer that only saw the stream can produce the same top-level
  summary without parsing the full aggregate document.
  """
  @spec emit_end(sink(), Report.t()) :: :ok
  def emit_end(sink, %Report{} = report) do
    mutation = report.mutation || %{}

    summary = %{
      "version" => JsonReporter.schema_version(),
      "kind" => "end",
      "meta" => JsonReporter.meta_to_wire(report.meta),
      "aborted" => report.aborted == true,
      "abort_reason" => report.abort_reason,
      "total" => Map.get(mutation, :total, 0),
      "completed" => Map.get(mutation, :completed, 0),
      "killed" => Map.get(mutation, :killed, 0),
      "survived" => Map.get(mutation, :survived, 0),
      "timeout" => Map.get(mutation, :timeout, 0),
      "compile_error" => Map.get(mutation, :compile_error, 0),
      "kill_rate" => Map.get(mutation, :kill_rate, nil)
    }

    write_line(sink, summary)
  end

  # ---------------------------------------------------------------------------
  # Wire shape (shared with JsonReporter)
  # ---------------------------------------------------------------------------

  defp render_result(%{before_source: _} = result), do: result

  defp render_result(%{original_ast: ast, mutated_ast: mutated} = result) do
    before = Macro.to_string(ast)
    Map.merge(result, %{before: before, before_source: before, after: Macro.to_string(mutated)})
  end

  defp render_result(%{before: before} = result), do: Map.put(result, :before_source, before)

  defp compile_error_to_wire(%{} = entry) do
    %{
      "version" => JsonReporter.schema_version(),
      "id" => Map.fetch!(entry, :id),
      "file" => to_string(Map.fetch!(entry, :file)),
      "line" => Map.fetch!(entry, :line),
      "column" => Map.fetch!(entry, :column),
      "mutator" => Atom.to_string(Map.fetch!(entry, :mutator)),
      "message" => Map.fetch!(entry, :message)
    }
  end

  # ---------------------------------------------------------------------------
  # I/O
  # ---------------------------------------------------------------------------

  defp write_line(sink, map) do
    iodata = [:json.encode(map, &encoder/2), ?\n]

    cond do
      is_function(sink, 1) -> sink.(iodata)
      true -> IO.write(sink, iodata)
    end

    :ok
  end

  defp encoder(nil, _enc), do: ~c"null"
  defp encoder(value, enc), do: :json.encode_value(value, enc)
end
