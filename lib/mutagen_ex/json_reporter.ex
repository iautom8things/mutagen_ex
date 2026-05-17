defmodule MutagenEx.JsonReporter.Sanitizer do
  @moduledoc """
  Truncation + redaction of free-form text that flows into the v1 JSON
  document (warnings, compile-error messages, abort-detail messages, and
  any other string field that captures user-code-derived bytes).

  Contract: [`mutagen.json_schema`](../../.spec/specs/json_schema.spec.md)
  r10, r11.

  ## Why

  Stderr, exception messages, and `Macro.to_string/1` output flow
  verbatim into `warnings`, `compile_errors[].message`, and the abort
  detail block. Unbounded, they let a single mutated module spray
  multi-MB of compiler diagnostics — including source slices that may
  contain secrets — into a JSON report that, when written with the lax
  `--json <path>` flag, becomes a file-system-resident artifact. The
  sanitizer is the choke point that bounds these strings before they
  hit the wire.

  ## Truncation (r10)

  Every sanitized binary is capped at `byte_size_limit/0` bytes
  (default 4 KiB). When truncation occurs, the binary ends with the
  literal marker `" ... <N bytes truncated>"` where `N` is the
  byte-count that was dropped. Multibyte UTF-8 grapheme boundaries are
  respected on a best-effort basis — we truncate on a codepoint
  boundary rather than splitting a grapheme.

  ## Redaction (r11)

  Opt-in via application config:

      config :mutagen_ex, redact: [~r/AWS_SECRET[A-Z0-9_]+=\\S+/, "BEARER \\S+"]

  Each element of the list may be a `%Regex{}` or a binary regex
  source. Matches are replaced with the literal string `[REDACTED]`.
  Redaction runs BEFORE truncation so the replacement does not push
  redacted bytes past the cap and then drop them as truncated text.

  Default `redact:` is `[]` (no redaction).

  ## API

    * `clean/1` — full pass: redact then truncate. The standard entry
      point for all message and warning strings.
    * `clean/2` — same as `clean/1` but accepts an explicit opts list
      (`:byte_size_limit`, `:patterns`) for tests that need to override
      the default cap or pattern list without touching application env.
    * `truncate/2` — truncation only.
    * `apply_redactions/2` — redaction only.
  """

  @default_byte_size_limit 4 * 1024
  @redact_replacement "[REDACTED]"

  @doc """
  Default byte-size limit. The cap is fixed at 4 KiB in v1. A future
  version may make it configurable; until then, callers that need a
  different cap pass `:byte_size_limit` to `clean/2` (test seam) or
  `truncate/2` directly.
  """
  @spec byte_size_limit() :: pos_integer()
  def byte_size_limit, do: @default_byte_size_limit

  @doc """
  Redact (per application env `:redact`) then truncate (to 4 KiB).
  Returns the cleaned binary. Non-binary input is converted via
  `to_string/1` first; `nil` is returned unchanged so callers can chain
  with optional fields.
  """
  @spec clean(binary() | nil | iodata()) :: binary() | nil
  def clean(nil), do: nil

  def clean(value) do
    clean(value, [])
  end

  @doc """
  Same as `clean/1` but with explicit opts:

    * `:byte_size_limit` — pos_integer cap (default `byte_size_limit/0`)
    * `:patterns` — list of patterns (defaults to
      `Application.get_env(:mutagen_ex, :redact, [])`)
  """
  @spec clean(binary() | nil | iodata(), keyword()) :: binary() | nil
  def clean(nil, _opts), do: nil

  def clean(value, opts) do
    limit = Keyword.get(opts, :byte_size_limit, @default_byte_size_limit)
    patterns = Keyword.get(opts, :patterns, configured_patterns())

    value
    |> to_binary()
    |> apply_redactions(patterns)
    |> truncate(limit)
  end

  @doc """
  Truncate `bin` to at most `limit` bytes. When truncation happens,
  the returned binary ends with `" ... <N bytes truncated>"` and its
  total `byte_size/1` may exceed `limit` by the length of the marker.
  This is intentional: the marker is metadata about the truncation,
  not part of the captured payload, and downstream consumers need a
  visible signal that bytes were dropped.

  Multibyte safety: we split on a codepoint boundary so we never emit
  an invalid UTF-8 fragment. The marker bytes are pure ASCII.
  """
  @spec truncate(binary(), pos_integer()) :: binary()
  def truncate(bin, limit) when is_binary(bin) and is_integer(limit) and limit > 0 do
    case byte_size(bin) do
      n when n <= limit ->
        bin

      n ->
        dropped = n - limit
        prefix = safe_byte_prefix(bin, limit)
        prefix <> " ... <#{dropped} bytes truncated>"
    end
  end

  @doc """
  Apply each pattern in `patterns` to `bin`, replacing every match
  with `[REDACTED]`. Patterns may be `%Regex{}` or binary regex
  sources. Binary sources are compiled with `Regex.compile!/1` on each
  call; callers that care about performance should pre-compile.

  An empty pattern list is a no-op.
  """
  @spec apply_redactions(binary(), list()) :: binary()
  def apply_redactions(bin, patterns) when is_binary(bin) and is_list(patterns) do
    Enum.reduce(patterns, bin, fn pattern, acc ->
      regex = compile_pattern(pattern)
      Regex.replace(regex, acc, @redact_replacement)
    end)
  end

  # ---- internals ----

  defp configured_patterns do
    case Application.get_env(:mutagen_ex, :redact, []) do
      list when is_list(list) -> list
      _ -> []
    end
  end

  defp to_binary(bin) when is_binary(bin), do: bin

  defp to_binary(other) do
    try do
      to_string(other)
    rescue
      _ -> inspect(other)
    end
  end

  defp compile_pattern(%Regex{} = re), do: re

  defp compile_pattern(source) when is_binary(source) do
    Regex.compile!(source)
  end

  # Find the largest codepoint-aligned prefix of `bin` that fits in
  # `limit` bytes. We walk the binary by grapheme so a 4-byte emoji at
  # the boundary is never split mid-codepoint.
  defp safe_byte_prefix(bin, limit) when is_binary(bin) do
    case String.valid?(bin) do
      true -> safe_utf8_prefix(bin, limit)
      false -> binary_part(bin, 0, limit)
    end
  end

  defp safe_utf8_prefix(bin, limit) do
    do_safe_utf8_prefix(bin, limit, <<>>)
  end

  defp do_safe_utf8_prefix(<<>>, _limit, acc), do: acc

  defp do_safe_utf8_prefix(rest, limit, acc) do
    case String.next_grapheme(rest) do
      nil ->
        acc

      {grapheme, tail} ->
        gsize = byte_size(grapheme)

        if byte_size(acc) + gsize > limit do
          acc
        else
          do_safe_utf8_prefix(tail, limit, acc <> grapheme)
        end
    end
  end
end

defmodule MutagenEx.JsonReporter.Report do
  @moduledoc """
  In-memory shape the pipeline assembles before the JSON reporter
  serialises it.

  The struct mirrors the v1 schema documented in
  [`mutagen.json_schema`](../../.spec/specs/json_schema.spec.md). Every
  field is `nil`-able except `version` (which is implicit in the reporter)
  and `warnings` / `aborted` (which default to empty/false). Per `r5`,
  sub-blocks the pipeline never populated stay `nil` rather than absent —
  the reporter emits them as JSON `null` so the schema's shape is the same
  on success and abort.

  ## Field-by-field

    * `:meta` — `%{tool_version, elixir_version, otp_version, exunit_seed}`.
      Always populated by the orchestrator before any phase runs (`r5`).
    * `:scope` — list of resolved `%MutagenEx.ScopeResolver.Scope{}`
      records or anything with `:file`, `:line_range`, `:module`. Empty
      list pre-resolution.
    * `:tests` — `%MutagenEx.TestSelector.TestFilter{}`-shaped map
      (`:include`, `:exclude`, `:files`) or `nil`.
    * `:baseline` — `%{passed, failed, failures}` or `nil`.
    * `:coverage` — `%{covered_lines: %{file => lines}}` or `nil`.
    * `:mutation` — full mutation block (see `mutagen.json_schema.r3` for
      sub-fields) or `nil`.
    * `:warnings` — list of strings. May be empty but never `nil`.
    * `:aborted` — boolean. `false` for full success, `true` for any
      pre-completion exit.
    * `:abort_reason` — string or `nil`. Populated iff `aborted == true`.
    * `:details` — map or `nil`. Phase-supplied diagnostic context for
      aborts; emitted as an empty map on success/non-abort documents.
    * `:truncated` — boolean. `true` when the run completed only a
      prefix of the enumerated mutation sites because the aggregate
      `--budget-ms` wall-clock was exhausted (per `mutagen.cli.r13`).
      The mutation block reflects the partial results; `aborted` may
      still be `false` since a truncated run is a graceful early exit,
      not an abort.
  """

  defstruct meta: nil,
            scope: nil,
            tests: nil,
            baseline: nil,
            coverage: nil,
            mutation: nil,
            warnings: [],
            aborted: false,
            abort_reason: nil,
            details: nil,
            truncated: false

  @type t :: %__MODULE__{
          meta: map() | nil,
          scope: list() | nil,
          tests: map() | nil,
          baseline: map() | nil,
          coverage: map() | nil,
          mutation: map() | nil,
          warnings: [String.t()],
          aborted: boolean(),
          abort_reason: String.t() | nil,
          details: map() | nil,
          truncated: boolean()
        }
end

defmodule MutagenEx.JsonReporter do
  @moduledoc """
  Single owner of the v1 JSON output document for `mix mutagen`.

  Contract: [`mutagen.json_schema`](../../.spec/specs/json_schema.spec.md)
  r1-r9. Decision: [`mutagen.decision.json_reporter_owns_error`](../../.spec/decisions/json_reporter_owns_error.md).

  Both success and abort variants emit a document of the same schema family.
  The difference between the two is whether `aborted` is `false` or `true`
  and which sub-blocks are populated. There is no separate `ErrorReporter`
  module.

  ## API

    * `emit_report(report)` — full pipeline result. Returns `{iodata, 0}`.
    * `emit_error(report, abort_reason)` — abort variant. Returns
      `{iodata, exit_code}` where `exit_code != 0`.

  Per `mutagen.json_schema.r6`, neither function performs I/O. They return
  iodata so the calling Mix task can choose between `IO.write/1` and
  `File.write!/2` based on `Config.json_path`.

  The encoded document terminates with exactly one trailing newline (`r8`).

  ## Report struct

  `%Report{}` is the in-memory shape the pipeline assembles. Field-by-field
  it mirrors the schema (`r2`); fields the pipeline never populated are
  `nil` rather than missing (`r5`).

  ## JSON encoding

  Encoding uses Erlang/OTP 27+'s `:json` module — no third-party
  dependency, per `.spec/AGENTS.md`'s deps discipline. The custom encoder
  function maps `nil` to `null` (the default `:json` encoder refuses
  `nil`) and forwards every other value to `:json.encode_value/2`.

  Map keys come out alphabetically sorted by `:json.encode_map/2`, which
  is what we want — the schema documents top-level keys but the golden
  fixture comparison is byte-exact, so any non-deterministic ordering
  would break `r9`.
  """

  alias MutagenEx.JsonReporter.Report
  alias MutagenEx.JsonReporter.Sanitizer

  @behaviour MutagenEx.Pipeline.ReporterOkFacade
  @behaviour MutagenEx.Pipeline.ReporterErrorFacade

  @schema_version "1"

  @typedoc """
  Atom-shaped reason for any non-zero exit. Matches the vocabulary in
  `mutagen.json_schema.r5`.
  """
  @type abort_reason ::
          :missing_scope
          | :missing_tests
          | :invalid_timeout
          | :invalid_seed
          | :colon_syntax_unsupported
          | :module_not_found
          | :arity_required
          | :unrecognised_target
          | :file_not_found
          | :file_read_failed
          | :parse_error
          | :no_tests_match
          | :invalid_target
          | :invalid_line
          | :tag_walk_failed
          | :self_mutation_refused
          | :cover_already_running
          | :cover_module_unavailable
          | :module_beam_missing
          | :cover_compile_failed
          | :ex_unit_run_failed
          | :test_file_load_failed
          | :baseline_red
          | :unrecoverable_restore_failure
          | :flag_not_supported_in_v1
          | :unknown_flag
          | :invalid_input
          | :unsafe_json_path
          | :too_many_targets
          | :too_many_sites
          | :invalid_max_sites
          | :invalid_budget_ms

  @doc """
  Emit the success-shape JSON document.

  `report.aborted` MUST be `false`; this function will still succeed if
  given an aborted report but the caller should be using `emit_error/2` in
  that case. The exit code is always `0`.
  """
  @impl MutagenEx.Pipeline.ReporterOkFacade
  @spec emit_report(Report.t()) :: {iodata(), 0}
  def emit_report(%Report{} = report) do
    {encode(report), 0}
  end

  @doc """
  Emit the abort-shape JSON document.

  The `abort_reason` argument is normalised onto the report (overriding any
  prior value) so callers can build the report incrementally and let the
  reporter pick the exit code at the moment of emission.

  Exit code is `2` for all abort reasons in v1. The schema does not
  differentiate exit codes by reason (the JSON's `abort_reason` field
  carries that signal); we use `2` to distinguish from the conventional
  `1` ExUnit failure exit and from `0` success.
  """
  @impl MutagenEx.Pipeline.ReporterErrorFacade
  @spec emit_error(Report.t(), abort_reason()) :: {iodata(), pos_integer()}
  def emit_error(%Report{} = report, abort_reason) when is_atom(abort_reason) do
    aborted_report = %Report{
      report
      | aborted: true,
        abort_reason: Atom.to_string(abort_reason)
    }

    {encode(aborted_report), 2}
  end

  # ---------------------------------------------------------------------------
  # Encoding
  # ---------------------------------------------------------------------------

  # Build the wire-shape map from the in-memory `%Report{}` and encode.
  # The wire shape uses string keys (the schema is documented in terms of
  # JSON keys; we don't want to leak atom-key idioms into the contract).
  defp encode(%Report{} = report) do
    doc = to_wire(report)

    iodata = :json.encode(doc, &encoder/2)
    [iodata, ?\n]
  end

  # Schema r1 fixes `version` to the literal "1". The wire-shape builder
  # is the canonical place that string lives.
  defp to_wire(%Report{} = r) do
    %{
      "version" => @schema_version,
      "meta" => meta_to_wire(r.meta),
      "scope" => scope_to_wire(r.scope),
      "tests" => tests_to_wire(r.tests),
      "baseline" => baseline_to_wire(r.baseline),
      "coverage" => coverage_to_wire(r.coverage),
      "mutation" => mutation_to_wire(r.mutation),
      "warnings" => r.warnings || [],
      "aborted" => r.aborted == true,
      "abort_reason" => r.abort_reason,
      "details" => details_to_wire(r.details),
      "truncated" => r.truncated == true
    }
  end

  defp details_to_wire(nil), do: %{}
  defp details_to_wire(%{} = details), do: detail_value_to_wire(details)

  defp detail_value_to_wire(%{} = map) do
    Enum.into(map, %{}, fn {key, value} ->
      {detail_key_to_wire(key), detail_value_to_wire(value)}
    end)
  end

  defp detail_value_to_wire(list) when is_list(list), do: Enum.map(list, &detail_value_to_wire/1)
  defp detail_value_to_wire(value) when is_boolean(value), do: value
  defp detail_value_to_wire(value) when is_atom(value), do: Atom.to_string(value)
  defp detail_value_to_wire(value) when is_binary(value), do: Sanitizer.clean(value)
  defp detail_value_to_wire(value) when is_integer(value), do: value
  defp detail_value_to_wire(nil), do: nil

  defp detail_value_to_wire(value) do
    value
    |> inspect()
    |> Sanitizer.clean()
  end

  defp detail_key_to_wire(key) when is_atom(key), do: Atom.to_string(key)
  defp detail_key_to_wire(key) when is_binary(key), do: key
  defp detail_key_to_wire(key), do: to_string(key)

  # `meta` is always populated even on early errors (r5: "we know our
  # tool/elixir/otp version even on early error").
  defp meta_to_wire(nil), do: %{}

  defp meta_to_wire(meta) when is_map(meta) do
    %{
      "tool_version" => Map.get(meta, :tool_version),
      "elixir_version" => Map.get(meta, :elixir_version),
      "otp_version" => Map.get(meta, :otp_version),
      "exunit_seed" => Map.get(meta, :exunit_seed)
    }
  end

  defp scope_to_wire(nil), do: []

  defp scope_to_wire(records) when is_list(records) do
    Enum.map(records, fn
      %{file: file, line_range: %Range{first: f, last: l}, module: mod} ->
        %{
          "file" => to_string(file),
          "line_range" => [f, l],
          "module" => inspect(mod)
        }
    end)
  end

  defp tests_to_wire(nil), do: nil

  defp tests_to_wire(%{include: include, exclude: exclude, files: files}) do
    %{
      "include" => Enum.map(include, &filter_value_to_wire/1),
      "exclude" => Enum.map(exclude, &filter_value_to_wire/1),
      "files" => Enum.map(files, &to_string/1)
    }
  end

  defp filter_value_to_wire({:location, {path, line}}) do
    %{"kind" => "location", "file" => to_string(path), "line" => line}
  end

  defp filter_value_to_wire(value) when is_atom(value), do: Atom.to_string(value)
  defp filter_value_to_wire(value) when is_binary(value), do: value

  defp baseline_to_wire(nil), do: nil

  defp baseline_to_wire(%{passed: passed, failed: failed, failures: failures}) do
    %{
      "passed" => passed,
      "failed" => failed,
      "failures" => Enum.map(failures, &failure_to_wire/1)
    }
  end

  # The Mix task assembles baseline in already-wire form when building
  # the abort report (see partial_baseline in lib/mix/tasks/mutagen.ex);
  # pass it through unchanged.
  defp baseline_to_wire(%{"passed" => _, "failed" => _, "failures" => _} = m), do: m

  defp failure_to_wire({module, name}) do
    %{"module" => inspect(module), "name" => to_string(name)}
  end

  defp failure_to_wire(%{module: module, name: name}) do
    %{"module" => inspect(module), "name" => to_string(name)}
  end

  defp coverage_to_wire(nil), do: nil

  defp coverage_to_wire(%{covered_lines: covered_lines}) do
    wire =
      covered_lines
      |> Enum.map(fn {file, lines} ->
        sorted =
          cond do
            is_struct(lines, MapSet) -> lines |> MapSet.to_list() |> Enum.sort()
            is_list(lines) -> Enum.sort(lines)
          end

        {to_string(file), sorted}
      end)
      |> Enum.into(%{})

    %{"covered_lines" => wire}
  end

  defp mutation_to_wire(nil), do: nil

  defp mutation_to_wire(%{} = m) do
    %{
      "total" => Map.get(m, :total, 0),
      "completed" => Map.get(m, :completed, 0),
      "killed" => Map.get(m, :killed, 0),
      "survived" => Map.get(m, :survived, 0),
      "timeout" => Map.get(m, :timeout, 0),
      "compile_error" => Map.get(m, :compile_error, 0),
      "kill_rate" => Map.get(m, :kill_rate, nil),
      "results" => Enum.map(Map.get(m, :results, []), &result_to_wire/1),
      "skipped" => Enum.map(Map.get(m, :skipped, []), &skipped_to_wire/1),
      "compile_errors" => Enum.map(Map.get(m, :compile_errors, []), &compile_error_to_wire/1),
      "state_drift_warning" => state_drift_to_wire(Map.get(m, :state_drift_warning, %{}))
    }
  end

  defp result_to_wire(%{} = result) do
    %{
      "id" => Map.fetch!(result, :id),
      "file" => to_string(Map.fetch!(result, :file)),
      "line" => Map.fetch!(result, :line),
      "column" => Map.fetch!(result, :column),
      "mutator" => Atom.to_string(Map.fetch!(result, :mutator)),
      "before" => Map.fetch!(result, :before),
      "before_source" => Map.fetch!(result, :before_source),
      "after" => Map.fetch!(result, :after),
      "status" => Atom.to_string(Map.fetch!(result, :status)),
      "tainted_predecessors" => Map.get(result, :tainted_predecessors, false) == true,
      "warnings" => Map.get(result, :warnings, [])
    }
  end

  defp skipped_to_wire(%{} = entry) do
    %{
      "site_id" => Map.fetch!(entry, :site_id),
      "reason" => Atom.to_string(Map.fetch!(entry, :reason)),
      "mutator" => Atom.to_string(Map.fetch!(entry, :mutator)),
      "file" => to_string(Map.fetch!(entry, :file))
    }
  end

  defp compile_error_to_wire(%{} = entry) do
    %{
      "id" => Map.fetch!(entry, :id),
      "file" => to_string(Map.fetch!(entry, :file)),
      "line" => Map.fetch!(entry, :line),
      "column" => Map.fetch!(entry, :column),
      "mutator" => Atom.to_string(Map.fetch!(entry, :mutator)),
      "message" => Map.fetch!(entry, :message)
    }
  end

  defp state_drift_to_wire(%{} = drift) do
    Enum.into(drift, %{}, fn {module, used_modules} ->
      {inspect(module), Enum.map(used_modules, &inspect/1)}
    end)
  end

  # ---------------------------------------------------------------------------
  # :json encoder hook
  # ---------------------------------------------------------------------------

  # OTP's `:json` refuses bare `nil`. Map it to JSON null; forward
  # everything else to the default value encoder.
  defp encoder(nil, _enc), do: ~c"null"
  defp encoder(value, enc), do: :json.encode_value(value, enc)
end
