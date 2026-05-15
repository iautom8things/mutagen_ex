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
status: draft
summary: Stable v1 JSON output schema for success, partial, and error runs.
surface:
  - lib/mutagen_ex/json_reporter.ex
  - test/mutagen_ex/golden/
decisions:
  - mutagen.decision.json_reporter_owns_error
  - mutagen.decision.content_addressed_ids
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
    `null` on success.

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
    `before_source` (string — verbatim source slice by line/col),
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
    Each `mutation.results[].before` and `mutation.results[].before_source`
    pair is rendered from a single `Macro.to_string(result.original_ast)`
    call per result — the resulting binary is aliased into both fields.
    Equivalently, for a run that emits R results, `Macro.to_string/1`
    is invoked at most `2 * R` times in the report-rendering path
    (once per result for `original_ast`, once per result for
    `mutated_ast`). In v1 `before_source` and `before` are
    byte-identical; a verbatim-source-slice implementation of
    `before_source` is a separate change that does not relax this
    call-count cap.
```

```spec-scenarios
- id: mutagen.json_schema.s1
  covers: [mutagen.json_schema.r1, mutagen.json_schema.r2]
  given: A pipeline run that completes cleanly with 10 mutation sites,
         9 killed and 1 survived.
  when: `JsonReporter.emit_report/1` is called with the resulting report.
  then: |
    The document has `version: "1"`, `aborted: false`, `abort_reason:
    null`. `mutation.total == 10`, `mutation.killed == 9`, `mutation.survived
    == 1`, `mutation.kill_rate == 0.9`.

- id: mutagen.json_schema.s2
  covers: [mutagen.json_schema.r3, mutagen.json_schema.r4]
  given: |
    A `%Report{}` fixture for `mutation_with_skipped.json` (4 completed
    sites: 3 killed + 1 survived; 2 sites in `skipped`; 1 site in
    `compile_errors`).
  when: `JsonReporter.emit_report/1` is called.
  then: |
    `mutation.total == 4`, `mutation.completed == 4`, `mutation.kill_rate
    == 0.75` (3 killed / 4 non-compile-error), `mutation.skipped` has 2
    entries, `mutation.compile_errors` has 1 entry, `mutation.results` has 4
    entries each with the full set of fields per r4.

- id: mutagen.json_schema.s3
  covers: [mutagen.json_schema.r5]
  given: A run where `--scope` is missing.
  when: The error path emits the document.
  then: |
    `version: "1"`, `aborted: true`, `abort_reason: "missing_scope"`.
    `baseline`, `coverage`, `mutation` are all `null`. `meta` is populated
    (we know our tool/elixir/otp version even on early error).

- id: mutagen.json_schema.s4
  covers: [mutagen.json_schema.r6]
  given: |
    A `%Report{}` fixture with `aborted: true, abort_reason:
    :baseline_red`.
  when: `JsonReporter.emit_report/1` is called.
  then: |
    Return is `{iodata, exit_code}` where `exit_code != 0`. The caller is
    responsible for `IO.puts`. The function itself made no I/O.

- id: mutagen.json_schema.s5
  covers: [mutagen.json_schema.r7, mutagen.json_schema.r8]
  given: A successful run's emitted document.
  when: We decode the iodata with `:json.decode/1`.
  then: |
    Decoding succeeds. The decoded map's `:version` key (or `"version"`)
    equals `"1"`. The last byte of the iodata is `\n`.

- id: mutagen.json_schema.s6
  covers: [mutagen.json_schema.r9]
  given: The 6 golden fixtures listed in r9.
  when: For each, we call `JsonReporter.emit_report(fixture)` and compare to
        the file contents.
  then: |
    Each comparison is byte-equal. Schema drift fails the golden test
    suite loudly.

- id: mutagen.json_schema.s7
  covers: [mutagen.json_schema.r10]
  given: |
    A captured stderr binary of 10_240 bytes (well over the 4 KiB cap)
    composed of repeating `"warning line\n"` so the boundary lands on
    a codepoint.
  when: |
    The binary flows into `mutation.results[i].warnings[0]` via the
    runner's `compose_warnings/1`.
  then: |
    The emitted warning string is exactly 4096 bytes of payload
    followed by ` ... <6144 bytes truncated>`. The full emitted
    binary is valid UTF-8.

- id: mutagen.json_schema.s8
  covers: [mutagen.json_schema.r11]
  given: |
    `Application.put_env(:mutagen_ex, :redact, [~r/SECRET_TOKEN=\S+/])`.
    A warning string `"warning: bad value SECRET_TOKEN=hunter2 in
    line 42"`.
  when: The warning flows through `compose_warnings/1`.
  then: |
    The emitted warning string contains `[REDACTED]` in place of
    `SECRET_TOKEN=hunter2` and does NOT contain the literal substring
    `hunter2`.

- id: mutagen.json_schema.s9
  covers: [mutagen.json_schema.r12]
  given: |
    A `%Report{}` fixture with N completed-mutation results, each
    carrying an `original_ast` whose `Macro.to_string/1` is observable
    via a counter (test seam — for the actual production path, the
    rendering helper computes it once explicitly).
  when: `mutation_to_report/2` renders the wire-shape map.
  then: |
    For every result in the rendered output, the `before` and
    `before_source` fields are the SAME binary value (byte-identical
    AND, in tests, pointer-equal). The total `Macro.to_string/1`
    invocation count over the render pass is at most `2 * N` (the
    `2 *` accounts for original + mutated; the cap is exactly the
    no-redundancy budget).
```

```spec-verification
- id: mutagen.json_schema.v1
  covers:
    - mutagen.json_schema.r1
    - mutagen.json_schema.r2
    - mutagen.json_schema.r3
    - mutagen.json_schema.r4
  kind: command
  command: mix test test/mutagen_ex/json_reporter_test.exs
  execute: true

- id: mutagen.json_schema.v2
  covers: [mutagen.json_schema.r5]
  kind: command
  command: mix test test/mutagen_ex/json_reporter_test.exs --only error_variants
  execute: true

- id: mutagen.json_schema.v3
  covers: [mutagen.json_schema.r9]
  kind: command
  command: mix test test/mutagen_ex/json_reporter_golden_test.exs
  execute: true

- id: mutagen.json_schema.v4
  covers:
    - mutagen.json_schema.r6
    - mutagen.json_schema.r7
    - mutagen.json_schema.r8
  kind: command
  command: mix test test/mutagen_ex/json_reporter_test.exs --only contract
  execute: true

- id: mutagen.json_schema.v5
  covers:
    - mutagen.json_schema.r10
    - mutagen.json_schema.r11
  kind: command
  command: mix test test/mutagen_ex/sanitizer_test.exs
  execute: true

- id: mutagen.json_schema.v6
  covers: [mutagen.json_schema.r12]
  kind: command
  command: mix test test/mutagen_ex/mutagen_task_render_test.exs
  execute: true
```
