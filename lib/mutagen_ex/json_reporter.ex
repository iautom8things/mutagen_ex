defmodule MutagenEx.JsonReporter.Sanitizer do
  @moduledoc """
  Truncation + redaction of free-form text that flows into the version 2 JSON
  document (warnings, compile-error messages, abort-detail messages, and
  any other string field that captures user-code-derived bytes).

  Contract: [`mutagen.json_schema`](../../.spec/specs/json_schema.spec.md)
  r10, r11.

  Compiler diagnostics and exception messages can include credentials or
  large excerpts from host code. This module redacts and bounds those
  messages before the reporter serializes them.

  ## Truncation (r10)

  Every sanitized binary is capped at `byte_size_limit/0` bytes
  (default 4 KiB). When truncation occurs, the binary ends with the
  literal marker `" ... <N bytes truncated>"` where `N` is the
  byte-count that was dropped. Multibyte UTF-8 grapheme boundaries are
  respected on a best-effort basis — we truncate on a codepoint
  boundary rather than splitting a grapheme.

  ## Redaction (r11)

  Built-in patterns redact URL userinfo, common credential keys, and
  token prefixes. Add patterns via application config:

      config :mutagen_ex, redact: [~r/AWS_SECRET[A-Z0-9_]+=\\S+/, "BEARER \\S+"]

  Each element of the list may be a `%Regex{}` or a binary regex
  source. Matches are replaced with the literal string `[REDACTED]`.
  Redaction runs BEFORE truncation so the replacement does not push
  redacted bytes past the cap and then drop them as truncated text.

  The default extra pattern list is empty.

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
  alias MutagenEx.JsonReporter.Redactor

  defdelegate secret_key?(key), to: Redactor

  @doc false
  def put_patterns(patterns), do: Process.put(__MODULE__, patterns)

  @doc false
  def with_patterns(patterns, fun) do
    previous = put_patterns(patterns)

    try do
      fun.()
    after
      if previous, do: Process.put(__MODULE__, previous), else: Process.delete(__MODULE__)
    end
  end

  @doc """
  Default byte-size limit. The cap is fixed at 4 KiB in v1. A future
  version may make it configurable; until then, callers that need a
  different cap pass `:byte_size_limit` to `clean/2` (test seam) or
  `truncate/2` directly.
  """
  @spec byte_size_limit() :: pos_integer()
  def byte_size_limit, do: @default_byte_size_limit

  @doc """
  Apply built-in and configured redactions, then truncate to 4 KiB.
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
    patterns = Keyword.get_lazy(opts, :patterns, &configured_patterns/0)

    input = to_binary(value)

    head =
      if byte_size(input) > Redactor.input_limit(),
        do: safe_byte_prefix(input, Redactor.input_limit()),
        else: input

    input_dropped = byte_size(input) - byte_size(head)

    {head, dropped} =
      case {input_dropped, truncation_marker(head, limit)} do
        {0, {offset, removed}} -> {binary_part(head, 0, offset), removed}
        _ -> {head, input_dropped}
      end

    redacted = head |> text() |> Redactor.redact(compile_patterns!(patterns))

    cond do
      redacted == Redactor.failure() -> redacted
      dropped == 0 -> truncate(redacted, limit)
      true -> append_truncation(redacted, limit, dropped)
    end
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
    if byte_size(bin) <= limit or truncation_marker(bin, limit) do
      bin
    else
      append_truncation(bin, limit, 0)
    end
  end

  defp append_truncation(bin, limit, already_dropped) do
    prefix = if byte_size(bin) > limit, do: safe_byte_prefix(bin, limit), else: bin
    dropped = already_dropped + byte_size(bin) - byte_size(prefix)
    prefix <> " ... <#{dropped} bytes truncated>"
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
    Redactor.apply_patterns(bin, compile_patterns!(patterns))
  end

  @doc false
  def source(nil), do: nil

  def source(value) when is_binary(value), do: truncate(text(value), @default_byte_size_limit)

  defp text(value) do
    value
    |> String.replace_invalid("")
    |> String.replace(~r/[\x00-\x08\x0B-\x1F\x7F-\x9F\p{Cf}]/u, "")
  end

  defp configured_patterns do
    Process.get(__MODULE__) || Application.get_env(:mutagen_ex, :redact, [])
  end

  defp compile_patterns!([%Regex{} | _] = patterns) do
    if Enum.all?(patterns, &is_struct(&1, Regex)), do: patterns, else: compile_sources!(patterns)
  end

  defp compile_patterns!([]), do: []
  defp compile_patterns!(patterns), do: compile_sources!(patterns)

  defp compile_sources!(patterns) do
    case Redactor.compile(patterns) do
      {:ok, compiled} -> compiled
      :error -> raise ArgumentError, "invalid mutagen :redact configuration"
    end
  end

  defp truncation_marker(bin, limit) do
    if byte_size(bin) in (limit + 1)..(limit + 40) do
      offset = max(0, limit - 40)
      tail = binary_part(bin, offset, byte_size(bin) - offset)

      case Regex.run(~r/ \.\.\. <([1-9][0-9]*) bytes truncated>\z/, tail, return: :index) do
        [{at, _}, {digits, length}] when offset + at <= limit ->
          {offset + at, tail |> binary_part(digits, length) |> String.to_integer()}

        _ ->
          nil
      end
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

  defp safe_byte_prefix(bin, limit) do
    aligned_byte_prefix(bin, limit)
  end

  defp aligned_byte_prefix(_bin, 0), do: ""

  defp aligned_byte_prefix(bin, limit) do
    if Bitwise.band(:binary.at(bin, limit), 0b11000000) == 0b10000000 do
      aligned_byte_prefix(bin, limit - 1)
    else
      binary_part(bin, 0, limit)
    end
  end
end

defmodule MutagenEx.JsonReporter.Report do
  @moduledoc """
  In-memory shape the pipeline assembles before the JSON reporter
  serialises it.

  The struct mirrors the version 2 schema documented in
  [`mutagen.json_schema`](../../.spec/specs/json_schema.spec.md). Every
  field is `nil`-able except `version` (which is implicit in the reporter)
  and `warnings` / `aborted` (which default to empty/false). Per `r5`,
  sub-blocks the pipeline never populated stay `nil` rather than absent —
  the reporter emits them as JSON `null` so the schema's shape is the same
  on success and abort.

  ## Field-by-field

    * `:meta` — versions, ExUnit seed, and the optional `:fail_fast` setting.
      The reporter adds `id_scheme` on the wire.
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
            truncated: false,
            source: true,
            include_host_output: false

  @type t :: %__MODULE__{
          meta: map() | nil,
          scope: list() | nil,
          tests: map() | nil,
          baseline: map() | nil,
          coverage: map() | nil,
          mutation: map() | nil,
          warnings: [String.t() | {atom(), String.t()} | {:host_names, atom(), [term()]}],
          aborted: boolean(),
          abort_reason: String.t() | nil,
          details: map() | nil,
          truncated: boolean(),
          source: boolean(),
          include_host_output: boolean()
        }
end

defmodule MutagenEx.JsonReporter do
  @moduledoc """
  Single owner of the version 2 JSON output document for `mix mutagen`.

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

  alias MutagenEx.JsonReporter.{Provenance, Report, Sanitizer}
  alias MutagenEx.Mutators

  @behaviour MutagenEx.Pipeline.ReporterOkFacade
  @behaviour MutagenEx.Pipeline.ReporterErrorFacade

  @schema_version "2"
  @id_scheme "2"

  @doc false
  def schema_version, do: @schema_version

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
          | :function_not_found
          | :invalid_tag_name
          | :invalid_max_concurrency
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
          | :invalid_mix_env
          | :host_loadpaths_failed
          | :host_compile_failed
          | :host_app_start_failed
          | :runtime_load_failed
          | :test_helper_load_failed
          | :test_alias_failed
          | :host_setup_timeout
          | :invalid_boot_timeout
          | :umbrella_root
          | :coverage_timeout
          | :baseline_timeout
          | :invalid_redact_config
          | :no_tests_run

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

  defp to_wire(%Report{} = r) do
    %{
      "version" => @schema_version,
      "meta" => aggregate_meta_to_wire(r.meta),
      "scope" => scope_to_wire(r.scope),
      "tests" => tests_to_wire(r.tests, r.include_host_output),
      "baseline" => baseline_to_wire(r.baseline, r.include_host_output),
      "coverage" => coverage_to_wire(r.coverage),
      "mutation" => mutation_to_wire(r.mutation, r),
      "warnings" => warnings_to_wire(Enum.uniq(r.warnings || []), r) |> Enum.uniq(),
      "aborted" => r.aborted == true,
      "abort_reason" => r.abort_reason,
      "details" => details_to_wire(r.details, r.abort_reason, r.include_host_output),
      "truncated" => r.truncated == true
    }
  end

  @structured_details ~w(file line column origin_file origin_line module exception reason phase step
                          note flag site_id passed failed failures excluded skipped include exclude
                          limit cap count actual max_sites)a

  defp details_to_wire(details, reason, include_host_output) do
    details = details || %{}

    details =
      if include_host_output do
        details
      else
        details
        |> Map.take(@structured_details)
        |> Map.update(:reason, nil, &default_reason/1)
        |> Map.reject(fn {key, value} -> key == :reason and is_nil(value) end)
      end

    details
    |> Map.drop([:include, :exclude, :exception, :failures])
    |> detail_value_to_wire()
    |> put_filter_details(details, include_host_output)
    |> put_failure_details(details, include_host_output)
    |> put_exception(details, include_host_output)
    |> put_hint(reason)
  end

  defp put_filter_details(wire, details, include_host_output) do
    Enum.reduce([:include, :exclude], wire, fn key, acc ->
      case Map.fetch(details, key) do
        {:ok, filters} when is_list(filters) ->
          Map.put(
            acc,
            Atom.to_string(key),
            Enum.map(filters, &filter_to_wire(&1, include_host_output))
          )

        _ ->
          acc
      end
    end)
  end

  defp put_failure_details(wire, %{failures: failures}, include_host_output) do
    Map.put(wire, "failures", failures_to_wire(failures, include_host_output))
  end

  defp put_failure_details(wire, _details, _include_host_output), do: wire

  defp put_exception(wire, %{exception: exception}, include_host_output)
       when not is_nil(exception) do
    value =
      cond do
        include_host_output and is_binary(exception) ->
          Sanitizer.clean(exception)

        include_host_output or Provenance.compiled_module?(exception) ->
          Sanitizer.clean(inspect(exception))

        true ->
          "host exception"
      end

    Map.put(wire, "exception", value)
  end

  defp put_exception(wire, _details, _include_host_output), do: wire

  defp default_reason(reason) when is_atom(reason) do
    if hint(Atom.to_string(reason)), do: reason, else: :host_reason
  end

  defp default_reason(_), do: :host_reason

  defp put_hint(details, nil), do: details

  defp put_hint(details, reason) do
    details
    |> Map.put("hint", hint(reason) || "Check the inputs and diagnostics on stderr.")
    |> Map.put(
      "note",
      "Stderr may carry unredacted host output. Do not publish it as a CI artifact."
    )
  end

  defp hint(reason) do
    case reason do
      "missing_scope" ->
        "Pass --scope with a source file, module or function."

      "missing_tests" ->
        "Pass --tests with a test file, location or tag."

      "invalid_timeout" ->
        "Pass a positive integer to --timeout-ms."

      "invalid_seed" ->
        "Pass a non-negative integer to --seed."

      "invalid_boot_timeout" ->
        "Pass a positive integer to --boot-timeout-ms."

      "invalid_budget_ms" ->
        "Pass a positive integer to --budget-ms."

      "invalid_max_sites" ->
        "Pass a positive integer to --max-sites."

      "invalid_max_concurrency" ->
        "Pass a positive integer to --max-concurrency."

      "invalid_redact_config" ->
        "Set :mutagen_ex, :redact to a list of valid regular expressions."

      "invalid_mix_env" ->
        "Run the command with MIX_ENV=test."

      "umbrella_root" ->
        "Run from the umbrella child that owns the tests."

      "runtime_load_failed" ->
        "Reinstall the mutagen_ex archive and check for module name collisions."

      "host_loadpaths_failed" ->
        "Run mix loadpaths in the host test environment."

      "host_compile_failed" ->
        "Run mix compile in the host test environment."

      "host_app_start_failed" ->
        "Check runtime configuration and host application startup."

      "test_alias_failed" ->
        "Run the host test alias and check its setup steps."

      "host_setup_timeout" ->
        "Check the named startup step or increase --boot-timeout-ms."

      "test_helper_load_failed" ->
        "Check the test helper at the reported location."

      "coverage_timeout" ->
        "Narrow --tests or increase --boot-timeout-ms or --timeout-ms."

      "baseline_timeout" ->
        "Narrow --tests or increase --boot-timeout-ms or --timeout-ms."

      "baseline_red" ->
        "Fix the listed failing tests before running mutations."

      "no_tests_run" ->
        "Check the cited tests and the effective ExUnit filters."

      "module_not_found" ->
        "Check the module name and that its source compiles."

      "function_not_found" ->
        "Check the function name and arity against the source."

      "arity_required" ->
        "Use Module.function/arity for a function scope."

      "colon_syntax_unsupported" ->
        "Use Module.function/arity for a function scope."

      "unrecognised_target" ->
        "Check the format of the scope target."

      "file_not_found" ->
        "Check that the selected source or test file exists."

      "file_read_failed" ->
        "Check permissions on the reported file."

      "parse_error" ->
        "Fix the syntax at the reported file and line."

      "no_tests_match" ->
        "Choose a test target that resolves to a test file."

      "invalid_target" ->
        "Use a test file, file:line or tag:name as the test target."

      "invalid_line" ->
        "Use a positive test line number."

      "invalid_tag_name" ->
        "Check the spelling and format of the test tag."

      "self_mutation_refused" ->
        "Choose a scope outside MutagenEx."

      "cover_already_running" ->
        "Stop existing OTP coverage before running mutagen."

      "cover_module_unavailable" ->
        "Check that the Erlang tools application is installed."

      "module_beam_missing" ->
        "Compile the selected module in the host test environment."

      "cover_compile_failed" ->
        "Check that OTP coverage can instrument the selected module."

      "ex_unit_run_failed" ->
        "Check the ExUnit setup and formatters for the named phase."

      "test_file_load_failed" ->
        "Check that the reported test file loads after test_helper.exs."

      "unrecoverable_restore_failure" ->
        "Start a fresh VM and check the reported module."

      "flag_not_supported_in_v1" ->
        "Use the JSON report format."

      "invalid_input" ->
        "Check the arguments passed to mutagen."

      "unknown_flag" ->
        "Check the supported options with mix help mutagen."

      "unsafe_json_path" ->
        "Choose a path inside the project root or pass --unsafe-json-outside-project."

      "too_many_targets" ->
        "Reduce the number of scope or test targets."

      "too_many_sites" ->
        "Narrow --scope or increase --max-sites."

      _ ->
        nil
    end
  end

  defp detail_value_to_wire(%{} = map) do
    Enum.into(map, %{}, fn {key, value} ->
      key = detail_key_to_wire(key)

      {Sanitizer.clean(key),
       if(Sanitizer.secret_key?(key), do: "[REDACTED]", else: detail_value_to_wire(value))}
    end)
  end

  defp detail_value_to_wire(list) when is_list(list), do: Enum.map(list, &detail_value_to_wire/1)
  defp detail_value_to_wire(value) when is_boolean(value), do: value
  defp detail_value_to_wire(nil), do: nil
  defp detail_value_to_wire(value) when is_atom(value), do: Sanitizer.clean(Atom.to_string(value))
  defp detail_value_to_wire(value) when is_binary(value), do: Sanitizer.clean(value)
  defp detail_value_to_wire(value) when is_integer(value), do: value

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
  @doc false
  def meta_to_wire(nil), do: %{"id_scheme" => @id_scheme, "fail_fast" => true}

  def meta_to_wire(meta) when is_map(meta) do
    %{
      "id_scheme" => @id_scheme,
      "tool_version" => Map.get(meta, :tool_version),
      "elixir_version" => Map.get(meta, :elixir_version),
      "otp_version" => Map.get(meta, :otp_version),
      "exunit_seed" => Map.get(meta, :exunit_seed),
      "fail_fast" => Map.get(meta, :fail_fast, true)
    }
  end

  defp aggregate_meta_to_wire(%{timings_ms: timings} = meta) do
    wire_timings = Map.new(timings, fn {phase, ms} -> {to_string(phase), ms} end)
    Map.put(meta_to_wire(meta), "timings_ms", wire_timings)
  end

  defp aggregate_meta_to_wire(meta), do: meta_to_wire(meta)

  defp scope_to_wire(nil), do: []

  defp scope_to_wire(records) when is_list(records) do
    Enum.map(records, fn
      %{file: file, line_range: %Range{first: f, last: l}, module: mod} ->
        %{
          "file" => Sanitizer.clean(to_string(file)),
          "line_range" => [f, l],
          "module" => Sanitizer.clean(inspect(mod))
        }
    end)
  end

  defp tests_to_wire(nil, _include_host_output), do: nil

  defp tests_to_wire(%{include: include, exclude: exclude, files: files}, include_host_output) do
    %{
      "include" => Enum.map(include, &filter_to_wire(&1, include_host_output)),
      "exclude" => Enum.map(exclude, &filter_to_wire(&1, include_host_output)),
      "files" => Enum.map(files, &Sanitizer.clean(to_string(&1)))
    }
  end

  defp filter_to_wire({:helper_filter, _key, value}, true), do: filter_to_wire(value)
  defp filter_to_wire({:helper_filter, nil, _value}, false), do: "host tag"
  defp filter_to_wire({:helper_filter, key, _value}, false), do: filter_to_wire(key)
  defp filter_to_wire(value, _include_host_output), do: filter_to_wire(value)

  def filter_to_wire({:location, {path, line}}) do
    %{"kind" => "location", "file" => Sanitizer.clean(path), "line" => line}
  end

  def filter_to_wire({:location, path}) when is_binary(path) do
    %{"kind" => "location", "file" => Sanitizer.clean(path)}
  end

  def filter_to_wire({key, value}) do
    key = to_string(key)

    rendered =
      cond do
        Sanitizer.secret_key?(key) -> "[REDACTED]"
        is_binary(value) or is_atom(value) or is_number(value) -> to_string(value)
        true -> inspect(value)
      end

    Sanitizer.clean("#{key}:#{rendered}")
  end

  def filter_to_wire(value) when is_atom(value) or is_binary(value),
    do: value |> to_string() |> Sanitizer.clean()

  defp baseline_to_wire(nil, _include_host_output), do: nil

  defp baseline_to_wire(
         %{passed: passed, failed: failed, failures: failures},
         include_host_output
       ) do
    %{
      "passed" => passed,
      "failed" => failed,
      "failures" => failures_to_wire(failures, include_host_output)
    }
  end

  defp baseline_to_wire(
         %{"passed" => p, "failed" => f, "failures" => failures},
         include_host_output
       ) do
    baseline_to_wire(%{passed: p, failed: f, failures: failures}, include_host_output)
  end

  defp failures_to_wire(failures, true) do
    for failure <- failures do
      {module, name} = failure_fields(failure)
      %{"module" => Sanitizer.clean(module), "name" => Sanitizer.clean(name)}
    end
  end

  defp failures_to_wire(failures, false) do
    failures
    |> Enum.frequencies_by(fn failure -> failure |> failure_fields() |> elem(0) end)
    |> Enum.sort()
    |> Enum.map(fn {module, count} ->
      %{"module" => Sanitizer.clean(module), "count" => count}
    end)
  end

  defp failure_fields({module, name}), do: {inspect(module), to_string(name)}
  defp failure_fields(%{module: module, name: name}), do: failure_fields({module, name})
  defp failure_fields(%{"module" => module, "name" => name}), do: {module, name}

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

        {Sanitizer.clean(to_string(file)), sorted}
      end)
      |> Enum.into(%{})

    %{"covered_lines" => wire}
  end

  defp mutation_to_wire(nil, _options), do: nil

  defp mutation_to_wire(%{} = m, options) do
    %{
      "total" => Map.get(m, :total, 0),
      "completed" => Map.get(m, :completed, 0),
      "killed" => Map.get(m, :killed, 0),
      "survived" => Map.get(m, :survived, 0),
      "timeout" => Map.get(m, :timeout, 0),
      "compile_error" => Map.get(m, :compile_error, 0),
      "kill_rate" => Map.get(m, :kill_rate, nil),
      "results" => Enum.map(Map.get(m, :results, []), &result_to_wire(&1, options)),
      "skipped" => Enum.map(Map.get(m, :skipped, []), &skipped_to_wire/1),
      "compile_errors" =>
        Enum.map(Map.get(m, :compile_errors, []), &compile_error_to_wire(&1, options)),
      "state_drift_warning" => state_drift_to_wire(Map.get(m, :state_drift_warning, %{}))
    }
  end

  @doc false
  def result_to_wire(%{} = result, options \\ %Report{}) do
    result
    |> site_to_wire(options)
    |> Map.merge(%{
      "status" => Atom.to_string(Map.fetch!(result, :status)),
      "tainted_predecessors" => Map.get(result, :tainted_predecessors, false) == true,
      "warnings" => warnings_to_wire(Map.get(result, :warnings, []), options)
    })
    |> put_source(result, options)
  end

  defp site_to_wire(site, options) do
    mutator = Map.fetch!(site, :mutator)

    wire = %{
      "id" => Sanitizer.clean(Map.fetch!(site, :id)),
      "line" => Map.fetch!(site, :line),
      "column" => Map.fetch!(site, :column),
      "mutator" => Atom.to_string(mutator),
      "confidence" => mutator |> Mutators.confidence() |> Atom.to_string()
    }

    if options.source do
      Map.merge(wire, %{
        "file" => Sanitizer.clean(to_string(Map.fetch!(site, :file))),
        "function" => Sanitizer.source(Map.get(site, :function))
      })
    else
      wire
    end
  end

  defp put_source(wire, result, %{source: true}) do
    Enum.reduce([:before, :before_source, :after], wire, fn key, acc ->
      Map.put(acc, Atom.to_string(key), Sanitizer.source(Map.fetch!(result, key)))
    end)
  end

  defp put_source(wire, _result, _options), do: wire

  defp warnings_to_wire(warnings, options) do
    {host_names, ordinary} = Enum.split_with(warnings, &match?({:host_process_died, _}, &1))

    registered =
      render_host_names(
        :host_process_died,
        Enum.map(host_names, &elem(&1, 1)),
        options.include_host_output
      )

    registered ++
      Enum.flat_map(ordinary, fn
        {:host_output, text} ->
          if options.include_host_output, do: [Sanitizer.clean(text)], else: []

        {:host_names, kind, names} ->
          render_host_names(kind, names, options.include_host_output)

        {:host_supervisor_changed, name} ->
          [Sanitizer.clean("host_supervisor_changed: #{name}")]

        text ->
          [Sanitizer.clean(text)]
      end)
  end

  @doc """
  Renders host-derived names under a fixed warning kind. Use only a
  tool-owned kind. Runner warnings can also carry `{:host_names, kind, names}`
  to apply this policy at the JSON boundary.
  """
  def render_host_names(_kind, [], _include_host_output), do: []

  def render_host_names(:state_leak, sites, include_host_output?) do
    for {site_id, groups} <- sites do
      pieces =
        for {kind, deltas} <- groups, map_size(deltas) > 0 do
          "#{kind}: #{render_growth(deltas, include_host_output?)}"
        end

      Sanitizer.clean(
        "state_leak after site #{site_id}: #{Enum.join(pieces, ", ")}. " <>
          "Subsequent results carry tainted_predecessors: true"
      )
    end
  end

  def render_host_names(kind, names, true) do
    for name <- Enum.uniq(names) do
      text = if is_binary(name) or is_atom(name), do: to_string(name), else: inspect(name)
      Sanitizer.clean("#{kind}: #{text}")
    end
  end

  def render_host_names(:host_process_died, names, false) do
    count = length(Enum.uniq(names))
    noun = if count == 1, do: "process", else: "processes"
    ["host_process_died: #{count} registered #{noun}"]
  end

  def render_host_names(kind, names, false), do: ["#{kind}: #{length(Enum.uniq(names))}"]

  defp render_growth(deltas, true) do
    Enum.map_join(Enum.sort(deltas), ", ", fn {name, growth} ->
      "#{inspect(name)} +#{growth}"
    end)
  end

  defp render_growth(deltas, false) do
    "names=#{map_size(deltas)}, +#{Enum.sum(Map.values(deltas))}"
  end

  defp skipped_to_wire(%{} = entry) do
    %{
      "site_id" => Sanitizer.clean(Map.fetch!(entry, :site_id)),
      "reason" => Atom.to_string(Map.fetch!(entry, :reason)),
      "mutator" => Atom.to_string(Map.fetch!(entry, :mutator)),
      "file" => Sanitizer.clean(to_string(Map.fetch!(entry, :file)))
    }
  end

  @doc false
  def compile_error_to_wire(%{} = entry, options \\ %Report{}) do
    wire = site_to_wire(entry, options)

    wire =
      if options.source do
        Map.put(wire, "diagnostic", "Elixir could not compile the mutated source.")
      else
        wire
      end

    wire = put_exception(wire, entry, options.include_host_output)

    if options.include_host_output do
      Map.put(wire, "message", Sanitizer.clean(Map.fetch!(entry, :message)))
    else
      wire
    end
  end

  defp state_drift_to_wire(%{} = drift) do
    Enum.into(drift, %{}, fn {module, used_modules} ->
      {Sanitizer.clean(inspect(module)), Enum.map(used_modules, &Sanitizer.clean(inspect(&1)))}
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
