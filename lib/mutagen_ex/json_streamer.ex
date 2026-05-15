defmodule MutagenEx.JsonStreamer do
  @moduledoc """
  Per-site NDJSON line emitter for `mix mutagen --stream`.

  Contract: [`mutagen.json_schema`](../../.spec/specs/json_schema.spec.md)
  r10 (NDJSON line shape, byte-equal to the equivalent entry in the
  final aggregate document's `mutation.results` / `mutation.compile_errors`).

  Each line is a JSON object terminated by a single `\\n`. The wire
  shape mirrors what `MutagenEx.JsonReporter` emits inside the final
  document — that is, the same map keys and value encodings, plus a
  `kind` discriminator (`"result"` or `"compile_error"`) and the same
  `version` literal the aggregate uses. Consumers parsing line-by-line
  can route on `kind`:

      {"version":"1","kind":"start","total":42,"meta":{...}}
      {"version":"1","kind":"result","id":"...","status":"killed",...}
      {"version":"1","kind":"compile_error","id":"...","message":"..."}
      {"version":"1","kind":"end","aborted":false,"abort_reason":null,
       "kill_rate":0.81,...}

  `start` and `end` envelope lines bracket the run. Per-site `result`
  and `compile_error` lines are emitted in **input order** — the
  runner streams them through `:on_site_completed` AS the
  per-input-index task completes (via the `async_stream`'s ordered
  collection guarantee), which means the byte-identical-output gate
  holds for the concatenated NDJSON stream too.
  """

  alias MutagenEx.JsonReporter.Report

  @schema_version "1"

  @typedoc "I/O sink. Any iolist-accepting function or a device."
  @type sink :: (iodata() -> any()) | IO.device()

  @doc """
  Emit the `start` envelope line. Returns `:ok`.

  `total` is the total site count the runner will attempt; `meta` is
  the same `meta` block the final document carries (tool version,
  elixir/otp version, exunit_seed).
  """
  @spec emit_start(sink(), pos_integer() | non_neg_integer(), map()) :: :ok
  def emit_start(sink, total, meta) do
    write_line(sink, %{
      "version" => @schema_version,
      "kind" => "start",
      "total" => total,
      "meta" => meta_to_wire(meta)
    })
  end

  @doc """
  Emit a per-site `result` line (`status` ∈ killed/survived/timeout/error).

  `result_map` is the same shape the runner pushes through
  `:on_site_completed` — see
  `MutagenEx.MutationRunner.run/1`'s `t:site_result/0`.
  """
  @spec emit_result(sink(), map()) :: :ok
  def emit_result(sink, %{} = result_map) do
    write_line(sink, Map.put(result_to_wire(result_map), "kind", "result"))
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
  carries the aggregate counters (`total`, `killed`, `survived`,
  `timeout`, `compile_error`, `kill_rate`) AND the abort fields, so a
  consumer that only saw the stream can produce the same top-level
  summary without parsing the full aggregate document.
  """
  @spec emit_end(sink(), Report.t()) :: :ok
  def emit_end(sink, %Report{} = report) do
    mutation = report.mutation || %{}

    summary = %{
      "version" => @schema_version,
      "kind" => "end",
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

  defp meta_to_wire(nil), do: %{}

  defp meta_to_wire(meta) when is_map(meta) do
    %{
      "tool_version" => Map.get(meta, :tool_version),
      "elixir_version" => Map.get(meta, :elixir_version),
      "otp_version" => Map.get(meta, :otp_version),
      "exunit_seed" => Map.get(meta, :exunit_seed)
    }
  end

  defp result_to_wire(%{} = r) do
    %{
      "version" => @schema_version,
      "id" => Map.fetch!(r, :id),
      "file" => to_string(Map.fetch!(r, :file)),
      "line" => Map.fetch!(r, :line),
      "column" => Map.fetch!(r, :column),
      "mutator" => Atom.to_string(Map.fetch!(r, :mutator)),
      "before" => before_string(r),
      "before_source" => before_string(r),
      "after" => after_string(r),
      "status" => Atom.to_string(Map.fetch!(r, :status)),
      "tainted_predecessors" => Map.get(r, :tainted_predecessors, false) == true,
      "warnings" => Map.get(r, :warnings, [])
    }
  end

  defp before_string(%{original_ast: ast}), do: Macro.to_string(ast)
  defp before_string(%{before: text}) when is_binary(text), do: text

  defp after_string(%{mutated_ast: ast}), do: Macro.to_string(ast)
  defp after_string(%{after: text}) when is_binary(text), do: text

  defp compile_error_to_wire(%{} = entry) do
    %{
      "version" => @schema_version,
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
