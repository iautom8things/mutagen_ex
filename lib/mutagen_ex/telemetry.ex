defmodule MutagenEx.Telemetry do
  @moduledoc """
  Centralised dispatcher for the `:telemetry` events `mix mutagen` emits.

  Contract: [`mutagen.mutation_pipeline`](../../.spec/specs/mutation_pipeline.spec.md) r15.

  Consumers subscribe their own handlers via `:telemetry.attach/4` /
  `:telemetry.attach_many/4`; this module is the producer side only.
  Per the ticket's Out of Scope, `mutagen_ex` does NOT ship a
  telemetry-poller or any built-in subscriber.

  ## Event vocabulary

  Every event uses the prefix `[:mutagen_ex]` and a stable shape so
  consumers can attach handlers without parsing the codebase:

    * `[:mutagen_ex, :run, :start]` — emitted once when
      `Mix.Tasks.Mutagen.run/2` enters the pipeline.
      Measurements: `%{system_time: integer}`.
      Metadata: `%{config: Config.t()}`.

    * `[:mutagen_ex, :coverage, :stop]` — emitted once after the
      coverage phase returns.
      Measurements: `%{duration: native_time}`.
      Metadata: `%{covered_files: non_neg_integer, covered_lines: non_neg_integer}`.

    * `[:mutagen_ex, :baseline, :stop]` — emitted once after baseline.
      Measurements: `%{duration: native_time}`.
      Metadata: `%{passed: integer, failed: integer}`.

    * `[:mutagen_ex, :enumeration, :stop]` — emitted once after
      `MutagenEx.MutationEnumerator.enumerate/4` returns.
      Measurements: `%{sites: non_neg_integer}`.
      Metadata: `%{skipped: non_neg_integer}`.

    * `[:mutagen_ex, :site, :start]` — emitted from inside each per-site
      task body, before the per-site `ExUnit.run/0`.
      Measurements: `%{system_time: integer}`.
      Metadata: `%{site_id: String.t, file: String.t, line: pos_integer,
                   mutator: atom, index: pos_integer, total: pos_integer}`.

    * `[:mutagen_ex, :site, :stop]` — emitted from the runner after the
      per-site task returns (whether it completed, timed out, or
      errored).
      Measurements: `%{duration: native_time}`.
      Metadata: `%{site_id: String.t, file: String.t, line: pos_integer,
                   mutator: atom, status: :killed | :survived | :timeout
                   | :error | :compile_error, index: pos_integer,
                   total: pos_integer}`.

    * `[:mutagen_ex, :run, :stop]` — emitted once after the mutation
      phase returns (success or partial).
      Measurements: `%{duration: native_time}`.
      Metadata: `%{aborted: boolean, abort_reason: String.t | nil,
                   killed: non_neg_integer, survived: non_neg_integer,
                   timeout: non_neg_integer, compile_error: non_neg_integer,
                   error: non_neg_integer}`.

  All `duration` measurements are in `:erlang.monotonic_time/0` units;
  consumers convert to wall-clock units with
  `System.convert_time_unit(duration, :native, :millisecond)`.

  ## Span helpers

  Coverage / baseline / mutation / per-site spans use
  `:telemetry.span/3`, which is what handlers expect for
  `:start` + `:stop` paired events with shared `duration` measurement
  semantics. Pre-pipeline events (`run.start`, enumeration `.stop`) use
  `:telemetry.execute/3` because the pipeline doesn't enter them as a
  closure-wrapped block.
  """

  @app :mutagen_ex

  @typedoc """
  Stage names this module accepts. Each maps to a stable event name
  under `[:mutagen_ex, <stage>, :start|:stop]`.
  """
  @type stage :: :run | :coverage | :baseline | :enumeration | :site

  @doc """
  Emit a fire-and-forget event. Thin wrapper around `:telemetry.execute/3`
  so production callers do not need to know about the lowercase atom.
  Production-safe even when no handler is attached.
  """
  @spec execute([atom()], map(), map()) :: :ok
  def execute(event, measurements, metadata)
      when is_list(event) and is_map(measurements) and is_map(metadata) do
    :telemetry.execute(event, measurements, metadata)
  end

  @doc """
  Run `fun.()` wrapped in `[:start, :stop]` events for the given stage.

  Equivalent to `:telemetry.span/3` but with the `[:mutagen_ex, <stage>]`
  prefix pre-applied so callers stay concise.

  `fun` must return `{result, stop_metadata}`. The result is returned to
  the caller; `stop_metadata` is merged into `metadata` for the `.stop`
  event.
  """
  @spec span(stage(), map(), (-> {term(), map()})) :: term()
  def span(stage, metadata, fun)
      when is_atom(stage) and is_map(metadata) and is_function(fun, 0) do
    :telemetry.span([@app, stage], metadata, fun)
  end
end
