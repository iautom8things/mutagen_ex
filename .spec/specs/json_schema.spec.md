# mutagen.json_schema — stable v1 output contract

The single artifact every `mix mutagen` run emits. The verifier judge LLM and
every CI integration parse this document, so the schema is the most stable
part of the system: adding fields is allowed; removing or renaming requires a
`version` bump.

## Intent

One module (`MutagenEx.JsonReporter`) owns both success and error variants of
the schema, per mutagen.decision.json_reporter_owns_error. Every code path
that exits — success, baseline-red, unresolvable scope, unrecoverable restore
failure, partial mid-pipeline crash — emits a document of this schema. The
difference between success and abort is whether `aborted` is `false` or
`true` and which sub-blocks are populated.

The schema is documented here exhaustively; golden fixtures in
`test/mutagen_ex/golden/` serve as the executable reference.

## Out of scope for this subject

- Behavior that produces the data going into the schema (see other subjects).
- I/O — `JsonReporter.emit_report/1` returns `{iodata, exit_code}`. The Mix
  task does the actual `IO.puts` / `File.write!`, per the seam in
  [mutagen.cli](cli.spec.md).

```spec-meta
id: mutagen.json_schema
kind: integration
status: active
summary: Stable v1 JSON output schema for success, partial, and error runs.
surface:
  - lib/mutagen_ex/json_reporter.ex
  - lib/mutagen_ex/json_streamer.ex
  - test/mutagen_ex/golden/
decisions:
  - mutagen.decision.json_reporter_owns_error
  - mutagen.decision.content_addressed_ids
  - mutagen.decision.details_always_present
realized_by:
  api_boundary:
    - "MutagenEx.JsonReporter"
    - "MutagenEx.JsonStreamer"
```

## Schema (v1)

Top-level keys, all present in every variant unless noted:

- `version`: literal string `"1"`.
- `meta`: `{tool_version, elixir_version, otp_version, exunit_seed}`.
- `scope`: array of resolved scope records.
- `tests`: resolved test filter (the `{include, exclude, files}` triple).
- `baseline`: `{passed: int, failed: int, failures: [{module, name}]}` or
  `null` if baseline never ran.
- `coverage`: `{covered_lines: %{file => [int]}}` or `null` if coverage never
  ran.
- `mutation`: full mutation block (see r3) or `null` if mutation phase never
  ran.
- `warnings`: array of strings. May be empty.
- `aborted`: boolean. `false` for full pipeline completion; `true` for any
  pre-completion exit.
- `abort_reason`: string or `null`. Populated iff `aborted == true`.
- `truncated`: boolean. `false` on every normal run; `true` when the
  mutation phase exited early because an aggregate budget elapsed. See
  r13 for the contract and [mutagen.cli.r13](cli.spec.md) for the
  `--budget-ms` flag that drives it.
- `details`: map. `{}` on successful (`aborted: false`) runs; populated
  with the phase-supplied diagnostic context on aborts. See r16.

```spec-requirements
- id: mutagen.json_schema.r1
  priority: must
  statement: |
    `version` field equals the literal string `"1"`. Any future schema
    change that removes a field or alters semantics increments this; v1 is
    the only value `mutagen_ex` ever emits before such a change.

- id: mutagen.json_schema.r2
  priority: must
  statement: |
    Every successful (`aborted: false`) run emits a document with all
    top-level keys populated and non-null EXCEPT `abort_reason`, which is
    `null` on success. The `truncated` boolean is populated on every run
    (success or abort); it defaults to `false` and only flips to `true`
    under the budget-exhaustion path defined in r13.

- id: mutagen.json_schema.r3
  priority: must
  statement: |
    The `mutation` block, when present, has these subfields:
    `total` (int — enumerated-and-not-skipped sites),
    `completed` (int — sites that ran to a classification),
    `killed` (int),
    `survived` (int),
    `timeout` (int),
    `compile_error` (int),
    `kill_rate` (float — `killed / (total - compile_error)`, or `null` if
    denominator is 0),
    `results` (array — one entry per completed site),
    `skipped` (array — one entry per `{:skip, reason}` site),
    `compile_errors` (array — one entry per `:compile_error` site),
    `state_drift_warning` (object — one entry per module with `use`),
    `aborted` is a top-level field, not nested in `mutation`.

- id: mutagen.json_schema.r4
  priority: must
  statement: |
    Each `mutation.results[i]` entry has:
    `id` (string of shape `{file}:{ast_hash}:{mutator}` per
    mutagen.decision.content_addressed_ids),
    `file` (string, relative path),
    `line` (int),
    `column` (int),
    `mutator` (string, snake_case name),
    `before` (string — `Macro.to_string/1` of original AST),
    `before_source` (string — verbatim source slice taken from
      the `source_text` the AST was parsed from (the `source_text`
      half of an `MutagenEx.AstCache` entry) when end positions
      are available. The slice range is
      `{start_line, start_column}` (the leftmost descendant of the
      site's `original_ast`, derived at render time) through
      `{end_line, end_column}` (carried on
      `%MutagenEx.MutationEnumerator.Site{}` per
      `mutagen.mutation_enumeration.r8`), end-exclusive. When the
      enumerator could not derive `{end_line, end_column}` for the
      site (e.g. bare-literal sites attributed to a parent
      operator's metadata, or macro-expanded forms whose AST
      metadata lacks a reliable end position), `before_source`
      falls back to `Macro.to_string/1` of the original AST and
      aliases the same binary as `before`. The fallback is
      observable: on the slice path `before_source` is byte-equal
      to a hand-cut source slice of the same range and may differ
      from `before` (which is always the `Macro.to_string/1`
      output); on the fallback path `before_source === before`
      (same binary reference, `:erts_debug.same/2` returns true)),
    `after` (string — `Macro.to_string/1` of swapped AST),
    `status` (one of: `"killed"`, `"survived"`, `"timeout"`, `"error"`),
    `tainted_predecessors` (bool),
    `warnings` (array of strings).
    Note: `:compile_error` outcomes do NOT appear in `results`; they live
    in the parallel `compile_errors` array.

- id: mutagen.json_schema.r5
  priority: must
  statement: |
    Every abnormal exit (`aborted: true`) emits a document of the SAME
    schema. Sub-blocks that never ran are `null` rather than missing. The
    `abort_reason` field is a string describing why: e.g.
    `"missing_scope"`, `"invalid_timeout"`, `"colon_syntax_unsupported"`,
    `"module_not_found"`, `"arity_required"`, `"no_tests_match"`,
    `"self_mutation_refused"`, `"cover_already_running"`, `"baseline_red"`,
    `"unrecoverable_restore_failure"`, `"flag_not_supported_in_v1"`,
    `"unsafe_json_path"`.

- id: mutagen.json_schema.r6
  priority: must
  statement: |
    `JsonReporter.emit_report/1` returns `{iodata, exit_code :: 0 | non_neg_integer}`.
    It does not call `IO.puts`, `IO.write`, `System.halt`, or write to disk.
    The caller (the Mix task) performs the I/O. This is the seam that lets
    the Mix task state machine be unit-tested without spawning processes.

- id: mutagen.json_schema.r7
  priority: must
  statement: |
    The encoded document is valid JSON: it round-trips through
    `:json.decode/1` (OTP 27+) or an equivalent stdlib JSON decoder. UTF-8
    characters in source slices are encoded correctly (no replacement
    chars).

- id: mutagen.json_schema.r8
  priority: must
  statement: |
    Document terminates with exactly one trailing newline character. Stdout
    consumers downstream rely on line-buffered reads; the trailing newline
    is part of the contract.

- id: mutagen.json_schema.r9
  priority: must
  statement: |
    Golden fixtures live at `test/mutagen_ex/golden/*.json`. The fixture set
    includes at minimum:
    `baseline_red.json`,
    `coverage_partial_mutation_perfect.json`,
    `coverage_full_mutation_partial.json`,
    `error_unresolvable_scope.json`,
    `mutation_with_skipped.json`,
    `partial_report_cover_failure.json`.
    Each represents a `%Report{}` fixture struct in the corresponding test
    file; running `JsonReporter.emit_report(fixture)` produces a string
    that is byte-equal to the golden file.

- id: mutagen.json_schema.r10
  priority: must
  statement: |
    Every free-form text field that captures user-code-derived bytes —
    `mutation.results[].warnings[]`, `mutation.compile_errors[].message`,
    the abort-detail `message` for `:unrecoverable_restore_failure`,
    `:test_file_load_failed`, `:ex_unit_run_failed`,
    `:file_read_failed`, and `:parse_error` — is truncated at 4096 bytes
    (4 KiB) before emission. When truncation occurs, the emitted string
    ends with the literal marker ` ... <N bytes truncated>` where `N`
    is the byte-count that was dropped (`N == original_byte_size -
    4096`). The marker bytes themselves are not counted against the
    4 KiB cap — they are metadata about the truncation. Truncation
    splits on a codepoint boundary so the emitted string is always
    valid UTF-8.

- id: mutagen.json_schema.r11
  priority: must
  statement: |
    Application config `:redact` (read via `Application.get_env(:mutagen_ex,
    :redact, [])`) is a list of `%Regex{}` values or binary regex
    sources. Every text field covered by r10 has each configured
    pattern applied to it; matches are replaced with the literal
    string `[REDACTED]`. Redaction runs BEFORE truncation so the
    replacement is not pushed past the 4 KiB cap. Default `:redact` is
    `[]` (no-op).

- id: mutagen.json_schema.r12
  priority: must
  statement: |
    The report-rendering path invokes `Macro.to_string/1` at most
    `2 * R` times for a run that emits R results: once per result
    for `original_ast` (rendered into `before`) and once per
    result for `mutated_ast` (rendered into `after`). Computing
    `before_source` does NOT add `Macro.to_string/1` invocations:

      * When `{end_line, end_column}` are available for the site,
        `before_source` is a verbatim slice of `source_text` and
        is computed by direct byte indexing — no `Macro.to_string`
        call.
      * When `{end_line, end_column}` are unavailable,
        `before_source` falls back to aliasing the same binary
        already computed for `before` — also no additional
        `Macro.to_string` call.

    The `2 * R` cap is therefore exact: the renderer never invokes
    `Macro.to_string/1` more than twice per result regardless of
    which `before_source` path each site takes. (Pre-`mutagen-wrd.26`
    the renderer used `4 * R` calls — once per result for each of
    `before`, `before_source`, `after`, and an accidental duplicate
    via the legacy fallback. `mutagen-wrd.26` cached the
    `original_ast` rendering and aliased it into both `before` and
    `before_source`, getting to `2 * R`. `mutagen-wrd.34` made
    `before_source` a verbatim source slice when end positions are
    available; the cap continues to hold because the slice path
    uses byte indexing, not `Macro.to_string/1`.)

- id: mutagen.json_schema.r13
  priority: must
  statement: |
    `truncated` is a top-level boolean populated on every emitted document
    (success or abort). It defaults to `false` and flips to `true` iff the
    mutation phase exited early under an aggregate wall-clock budget. The
    `--budget-ms` flag and the runtime conditions that drive this flip are
    defined by [mutagen.cli.r13](cli.spec.md); this schema only pins the
    wire shape:

    - The key is always present at the top level (never omitted, never `null`).
    - On a normal completion, the value is `false`.
    - On a budget-exhaustion early exit, the value is `true`, `aborted`
      remains `false` (truncation is a graceful early exit, not an abort),
      `abort_reason` remains `null`, and the `mutation` block reflects only
      the sites the runner completed before the budget elapsed.
    - `warnings` contains at least one `budget_exceeded` entry when
      `truncated: true`.

- id: mutagen.json_schema.r14
  priority: must
  statement: |
    NDJSON streaming variant (`mix mutagen --stream`). When `--stream`
    is set, `MutagenEx.JsonStreamer` emits one JSON object per line to
    the same sink the aggregate document goes to (stdout when `--json`
    is absent, the configured file when `--json <path>` is set).
    Every line terminates with exactly one `\n` and is independently
    parseable by `:json.decode/1`. Every line carries:
      - `"version"` — the same literal `"1"` the aggregate document
        emits (`r1`).
      - `"kind"` — one of `"start"`, `"result"`, `"compile_error"`,
        `"end"`.
    The four kinds bracket the run:
      - `"start"` fires once at mutation-phase entry; carries `total`
        (planned site count) and `meta` (`r2`'s meta block).
      - `"result"` fires once per completed site (any of `killed`,
        `survived`, `timeout`, `error`); the line's wire shape MUST be
        byte-equal to the equivalent entry in the aggregate document's
        `mutation.results[]` array (`r4`) plus the `"kind"` and
        `"version"` discriminators.
      - `"compile_error"` fires once per `:compile_error` site; the
        line's wire shape MUST be byte-equal to the equivalent entry
        in `mutation.compile_errors[]`.
      - `"end"` fires once at pipeline exit (success or abort);
        carries the aggregate counters (`total`, `completed`,
        `killed`, `survived`, `timeout`, `compile_error`, `kill_rate`)
        AND `aborted` + `abort_reason`.
    Per-site lines (`"result"` / `"compile_error"`) are emitted in
    input order — async_stream's `:ordered: true` plus the runner's
    `:on_site_completed` sequential post-fold ensure a consumer
    concatenating the stream into the aggregate would reproduce
    `mutation.results[]` byte-equal to the standalone aggregate
    document's array.

- id: mutagen.json_schema.r15
  priority: must
  statement: |
    `JsonStreamer.emit_*` functions do not call `IO.puts`,
    `IO.write`, `System.halt`, or write to disk on their own. They
    take a `sink` argument (either an IO device atom like
    `:standard_io` or a `(iodata -> any)` function) and dispatch the
    encoded line to it. The Mix task chooses the sink: stdout for
    `--stream` without `--json`, an in-memory buffer that the final
    IO step flushes for `--stream --json <path>`. This mirrors
    `r6` (the aggregate reporter is also I/O-free) and lets unit
    tests of the streamer assert wire shape without touching the
    filesystem.

- id: mutagen.json_schema.r16
  priority: must
  statement: |
    The top-level `details` field is always present on every emitted
    document — never absent, never `null`, always a JSON object (map).

    Shape contract:

      - On successful (`aborted: false`) runs: `details == %{}` (empty
        map). The successful run carries no failing-phase diagnostic
        context to surface.
      - On aborted (`aborted: true`) runs: `details` contains the
        phase-supplied diagnostic context for the abort. Concrete
        examples from the production phases:
          * `:test_file_load_failed` → `{file: "test/foo_test.exs",
             message: "could not load test file ..."}`
          * `:module_beam_missing` → `{module: "Elixir.Foo", file:
             "lib/foo.ex", message: "no .beam file located ..."}`
          * `:cover_already_running` → `{message: "another :cover
             session is running"}`
          * `:too_many_targets` → `{flag: "--scope", kind: :scope,
             cap: 100, count: 101}`
        Phases own the shape of their own details map; this subject
        does not enumerate the keys, only the outer envelope.

    Leaf encoding: atom values are stringified (e.g. `kind: :scope` →
    `"kind": "scope"`); integer/boolean values pass through; binary
    leaves are sanitized through the r10 truncation + r11 redaction
    pipeline before emission. Map values may nest one layer deep
    (e.g. `failures: [...]` from baseline-red details).

    The `details` envelope is additive to the v1 schema. Consumers
    parsing v1 documents prior to this requirement see no `details`
    field at all; after this requirement the key is always present.
    Per the schema-evolution policy in this subject's intent
    (`adding fields is allowed`), `version` stays at `"1"`.

    Decision: mutagen.decision.details_always_present.

    Counter-example (pre-fix): a downstream user's `mix mutagen` aborts
    with `abort_reason: "test_file_load_failed"`. The emitted JSON
    contains only `abort_reason` and no detail context — the user
    cannot tell which test file failed to load, what the underlying
    Elixir exception was, or how to fix their input. After this
    requirement, the same abort emits `details: {file:
    "test/foo_test.exs", message: "cannot use ExUnit.Case without
    starting the ExUnit application, ..."}`.
```

```spec-scenarios
- id: mutagen.json_schema.s1
  covers:
    - mutagen.json_schema.r1
    - mutagen.json_schema.r2
  given:
    - A pipeline run that completes cleanly with 10 mutation sites, 9 killed and 1 survived.
  when:
    - "`JsonReporter.emit_report/1` is called with the resulting report."
  then:
    - "The document has `version: \"1\"`, `aborted: false`, `abort_reason: null`."
    - "`mutation.total == 10`, `mutation.killed == 9`, `mutation.survived == 1`, `mutation.kill_rate == 0.9`."

- id: mutagen.json_schema.s2
  covers:
    - mutagen.json_schema.r3
    - mutagen.json_schema.r4
  given:
    - A `%Report{}` fixture for `mutation_with_skipped.json` (4 completed sites; 3 killed + 1 survived; 2 sites in `skipped`; 1 site in `compile_errors`).
  when:
    - "`JsonReporter.emit_report/1` is called."
  then:
    - "`mutation.total == 4`, `mutation.completed == 4`, `mutation.kill_rate == 0.75` (3 killed / 4 non-compile-error)."
    - "`mutation.skipped` has 2 entries, `mutation.compile_errors` has 1 entry, `mutation.results` has 4 entries each with the full set of fields per r4."

- id: mutagen.json_schema.s3
  covers:
    - mutagen.json_schema.r5
  given:
    - A run where `--scope` is missing.
  when:
    - The error path emits the document.
  then:
    - "`version: \"1\"`, `aborted: true`, `abort_reason: \"missing_scope\"`."
    - "`baseline`, `coverage`, `mutation` are all `null`."
    - "`meta` is populated (we know our tool/elixir/otp version even on early error)."

- id: mutagen.json_schema.s4
  covers:
    - mutagen.json_schema.r6
  given:
    - "A `%Report{}` fixture with `aborted: true, abort_reason: :baseline_red`."
  when:
    - "`JsonReporter.emit_report/1` is called."
  then:
    - "Return is `{iodata, exit_code}` where `exit_code != 0`."
    - The caller is responsible for `IO.puts`. The function itself made no I/O.

- id: mutagen.json_schema.s5
  covers:
    - mutagen.json_schema.r7
    - mutagen.json_schema.r8
  given:
    - A successful run's emitted document.
  when:
    - "We decode the iodata with `:json.decode/1`."
  then:
    - "Decoding succeeds. The decoded map's `:version` key (or `\"version\"`) equals `\"1\"`."
    - "The last byte of the iodata is `\\n`."

- id: mutagen.json_schema.s6
  covers:
    - mutagen.json_schema.r9
  given:
    - The 6 golden fixtures listed in r9.
  when:
    - For each, we call `JsonReporter.emit_report(fixture)` and compare to the file contents.
  then:
    - Each comparison is byte-equal. Schema drift fails the golden test suite loudly.

- id: mutagen.json_schema.s7
  covers:
    - mutagen.json_schema.r10
  given:
    - A captured stderr binary of 10_240 bytes (well over the 4 KiB cap) composed of repeating `"warning line\n"` so the boundary lands on a codepoint.
  when:
    - The binary flows into `mutation.results[i].warnings[0]` via the runner's `compose_warnings/1`.
  then:
    - "The emitted warning string is exactly 4096 bytes of payload followed by ` ... <6144 bytes truncated>`."
    - The full emitted binary is valid UTF-8.

- id: mutagen.json_schema.s8
  covers:
    - mutagen.json_schema.r11
  given:
    - "`Application.put_env(:mutagen_ex, :redact, [~r/SECRET_TOKEN=\\S+/])`."
    - 'A warning string `"warning: bad value SECRET_TOKEN=hunter2 in line 42"`.'
  when:
    - The warning flows through `compose_warnings/1`.
  then:
    - The emitted warning string contains `[REDACTED]` in place of `SECRET_TOKEN=hunter2` and does NOT contain the literal substring `hunter2`.

- id: mutagen.json_schema.s9
  covers:
    - mutagen.json_schema.r12
    - mutagen.json_schema.r4
  given:
    - A `%Report{}` fixture with N completed-mutation results.
    - "Some results carry `end_line`/`end_column` and `source_text` (slice path); others carry `end_line: nil` (fallback path)."
  when:
    - "`mutation_to_report/2` renders the wire-shape map."
  then:
    - For every result on the FALLBACK path (`end_line == nil`), the rendered `before` and `before_source` fields share the SAME binary reference (`:erts_debug.same/2` returns true) — the `Macro.to_string(original_ast)` output is aliased into both.
    - For every result on the SLICE path (`end_line` non-nil), the rendered `before_source` is a verbatim slice of `source_text` by `{line, column, end_line, end_column}` and matches a hand-cut source slice byte-for-byte.
    - The total `Macro.to_string/1` invocation count over the render pass is AT MOST `2 * N` regardless of how the N results split between slice and fallback (the slice path uses byte indexing, not `Macro.to_string`).

- id: mutagen.json_schema.s16a
  covers:
    - mutagen.json_schema.r16
  given:
    - A successful pipeline run that completes with 5 mutation sites, all classified normally.
  when:
    - "`JsonReporter.emit_report/1` renders the document."
  then:
    - 'The decoded JSON has `"details": {}` at the top level. The map is empty (no keys).'
    - "The document round-trips through `:json.decode/1` per r7 with the `details` key present."

- id: mutagen.json_schema.s16b
  covers:
    - mutagen.json_schema.r16
  given:
    - A pipeline run that aborts in the coverage phase with `:test_file_load_failed` because the cited test file raises on load.
    - 'The phase returns `{:error, :test_file_load_failed, %{file: "test/foo_test.exs", message: "could not load test file \"test/foo_test.exs\": cannot use ExUnit.Case ..."}}`.'
  when:
    - "`JsonReporter.emit_error/2` renders the error document."
  then:
    - 'The decoded JSON has `"aborted": true`, `"abort_reason": "test_file_load_failed"`, AND a populated `"details"` map containing keys `"file"` (string `"test/foo_test.exs"`) and `"message"` (the binary, possibly truncated and/or redacted per r10/r11).'
    - The `details` map is NOT empty.

- id: mutagen.json_schema.s16c
  covers:
    - mutagen.json_schema.r16
    - mutagen.json_schema.r10
  given:
    - A pipeline run that aborts with a `details.message` of 10_240 bytes (over the 4 KiB r10 cap).
  when:
    - "`JsonReporter.emit_error/2` renders the error document."
  then:
    - "The decoded JSON's `details.message` is exactly 4096 bytes of payload followed by ` ... <6144 bytes truncated>`."
    - The sanitizer pipeline applied to abort-detail string leaves matches the sanitizer applied to `mutation.results[].warnings[]`.
```

```spec-verification
- id: mutagen.json_schema.v1
  covers:
    - mutagen.json_schema.r1
    - mutagen.json_schema.r2
    - mutagen.json_schema.r3
    - mutagen.json_schema.r4
  kind: command
  target: mix test test/mutagen_ex/json_reporter_test.exs
  execute: true

- id: mutagen.json_schema.v2
  covers: [mutagen.json_schema.r5]
  kind: command
  target: mix test test/mutagen_ex/json_reporter_test.exs --only error_variants
  execute: true

- id: mutagen.json_schema.v3
  covers: [mutagen.json_schema.r9]
  kind: command
  target: mix test test/mutagen_ex/json_reporter_golden_test.exs
  execute: true

- id: mutagen.json_schema.v4
  covers:
    - mutagen.json_schema.r6
    - mutagen.json_schema.r7
    - mutagen.json_schema.r8
  kind: command
  target: mix test test/mutagen_ex/json_reporter_test.exs --only contract
  execute: true

- id: mutagen.json_schema.v5
  covers:
    - mutagen.json_schema.r10
    - mutagen.json_schema.r11
  kind: command
  target: mix test test/mutagen_ex/sanitizer_test.exs
  execute: true

- id: mutagen.json_schema.v6
  covers: [mutagen.json_schema.r12]
  kind: command
  target: mix test test/mutagen_ex/mutagen_task_render_test.exs
  execute: true

- id: mutagen.json_schema.v7
  covers:
    - mutagen.json_schema.r14
    - mutagen.json_schema.r15
  kind: command
  target: mix test test/mutagen_ex/json_streamer_test.exs
  execute: true

- id: mutagen.json_schema.v8
  covers: [mutagen.json_schema.r16]
  kind: command
  target: mix test test/mutagen_ex/json_reporter_test.exs --only details_field
  execute: true

- id: mutagen.json_schema.v9
  covers: [mutagen.json_schema.r16]
  kind: command
  target: mix test test/mutagen_ex/json_reporter_golden_test.exs
  execute: true

- id: mutagen.json_schema.v10
  covers: [mutagen.json_schema.r13]
  kind: command
  target: mix test test/mutagen_ex/json_reporter_golden_test.exs
  execute: true
```
