# mutagen.json_schema — version 2 output contract

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
summary: Version 2 JSON output schema for success, partial, and error runs.
surface:
  - lib/mutagen_ex/json_reporter/redactor.ex
  - lib/mutagen_ex/json_reporter/provenance.ex
  - lib/mutagen_ex/json_reporter.ex
  - lib/mutagen_ex/json_streamer.ex
  - test/mutagen_ex/golden/baseline_red.json
  - test/mutagen_ex/golden/coverage_full_mutation_partial.json
  - test/mutagen_ex/golden/coverage_partial_mutation_perfect.json
  - test/mutagen_ex/golden/end_to_end_scenario_1_arith.json
  - test/mutagen_ex/golden/end_to_end_scenario_2_decisions.json
  - test/mutagen_ex/golden/end_to_end_scenario_3_result_tuples.json
  - test/mutagen_ex/golden/end_to_end_scenario_3a_pipelined.json
  - test/mutagen_ex/golden/end_to_end_scenario_3b_guarded.json
  - test/mutagen_ex/golden/end_to_end_scenario_3c_withblock_with_swap.json
  - test/mutagen_ex/golden/end_to_end_scenario_3d_withblock_else_removal.json
  - test/mutagen_ex/golden/end_to_end_scenario_4_infinite_looper.json
  - test/mutagen_ex/golden/end_to_end_scenario_5_baseline_red.json
  - test/mutagen_ex/golden/end_to_end_scenario_6_zero_coverage.json
  - test/mutagen_ex/golden/end_to_end_scenario_7_ecto_user.json
  - test/mutagen_ex/golden/end_to_end_scenario_8_macro_holder.json
  - test/mutagen_ex/golden/error_unresolvable_scope.json
  - test/mutagen_ex/golden/mutation_with_skipped.json
  - test/mutagen_ex/golden/partial_report_cover_failure.json
decisions:
  - mutagen.decision.report_text_policy
  - mutagen.decision.mutation_site_paths
  - mutagen.decision.json_reporter_owns_error
  - mutagen.decision.mutation_id_scheme_2
  - mutagen.decision.per_mutant_fail_fast
  - mutagen.decision.details_always_present
  - mutagen.decision.mutator_confidence
  - mutagen.decision.mutator_precision
  - mutagen.decision.ancora_migration
  - mutagen.decision.host_test_setup
```

## Schema (version 2)

Top-level keys, all present in every variant unless noted:

- `version`: literal string `"2"`.
- `meta`: `{tool_version, elixir_version, otp_version, exunit_seed, id_scheme, fail_fast}`.
- `scope`: array of resolved scope records.
- `tests`: resolved test filter (the `{include, exclude, files}` triple).
- `baseline`: `{passed: int, failed: int, failures: [{module, count}]}` or
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
    `version` field equals the literal string `"2"`. Any future schema
    change that removes a field or alters semantics increments this.
    Every aggregate document and NDJSON start line carries
    `meta.id_scheme: "2"`.
    IDs and reports from earlier versions cannot be compared with version 2.
    Every aggregate document, error document and NDJSON start and end
    line also carries a boolean `meta.fail_fast`: the parsed
    `Config.fail_fast` (mutagen.cli.r17), or `true` when the run stopped
    before argument parsing succeeded.

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
    `total` (int, the completed results `killed + survived + timeout +
    error`; skipped and compile-error sites are not counted),
    `completed` (int, equal to `total`),
    `killed` (int),
    `survived` (int),
    `timeout` (int),
    `compile_error` (int),
    `kill_rate` (float, `killed / total`, or `null` when `total` is 0),
    `results` (array — one entry per completed site),
    `skipped` (array — one entry per `{:skip, reason}` site),
    `compile_errors` (array — one entry per `:compile_error` site),
    `state_drift_warning` (object — one entry per module with `use`),
    `aborted` is a top-level field, not nested in `mutation`.

- id: mutagen.json_schema.r4
  priority: must
  statement: |
    Each `mutation.results[i]` entry has the following fields, subject to r18:
    `id` (string of shape `{file}:{hash}:{mutator}` per
    mutagen.decision.mutation_id_scheme_2),
    `function` (string `Mod.fun/arity` for the enclosing definition, or null
    outside a function, with the same encoding in NDJSON result lines),
    `file` (string, relative path),
    `line` (int),
    `column` (int),
    `mutator` (string, snake_case name),
    `confidence` (string, `"high"` or `"low"`: the rating
    `MutagenEx.Mutators.confidence/1` returns for `mutator`, whatever the
    `status`),
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
      to a hand-cut source slice of the same range before output cleaning and may differ
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
    Every report abort (`aborted: true`) uses the same schema and returns
    exit code 2. Sub-blocks that never ran are `null`. The `abort_reason`
    field is the string form of one of the atoms in
    `MutagenEx.JsonReporter.abort_reason/0` (r20).


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
    Every emitted free-form text field that captures user-code-derived bytes —
    `mutation.results[].warnings[]`, `mutation.compile_errors[].message`,
    the opted-in abort-detail `message` for `:unrecoverable_restore_failure`,
    `:test_file_load_failed`, `:ex_unit_run_failed`,
    `:file_read_failed`, and `:parse_error` — is truncated at 4096 bytes
    (4 KiB) before emission. When truncation occurs, the emitted string
    ends with the literal marker ` ... <N bytes truncated>` where `N`
    is the byte-count that was dropped (`N == original_byte_size -
    4096`, adjusted for the UTF-8 boundary). The marker bytes themselves are not counted against the
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
    `[]`, which adds no patterns. The built-in redactions of r17 run
    first, so configured patterns see text that is already redacted.

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
      - `"version"` — the same literal `"2"` the aggregate document
        emits (`r1`).
      - `"kind"` — one of `"start"`, `"result"`, `"compile_error"`,
        `"end"`.
    The four kinds bracket the run from the enumeration phase on:
      - `"start"` fires once at mutation-phase entry; carries `total`
        (planned site count, every enumerated site that was not skipped)
        and `meta` (`r2`'s meta block). That `meta` equals the aggregate
        document's `meta`.
      - `"result"` fires once per completed site (any of `killed`,
        `survived`, `timeout`, `error`); the line's wire shape MUST be
        byte-equal to the equivalent entry in the aggregate document's
        `mutation.results[]` array (`r4`), including `function` and
        `confidence`, plus the `"kind"` and `"version"` discriminators.
      - `"compile_error"` fires once per `:compile_error` site; the
        line's wire shape MUST be byte-equal to the equivalent entry
        in `mutation.compile_errors[]`.
      - `"end"` fires once at pipeline exit (success or abort) for
        every run that reached the enumeration phase; carries `meta`,
        the aggregate counters (`total`, `completed`, `killed`,
        `survived`, `timeout`, `compile_error`, `kill_rate`)
        AND `aborted` + `abort_reason`. Its `total` is the aggregate
        `mutation.total` (`r3`), so it is lower than the start line's
        planned `total` when sites fail to compile or a budget truncates
        the run.
        It carries `meta.id_scheme` even when the run aborted in
        enumeration or baseline, before the start line.
    Per-site lines (`"result"` / `"compile_error"`) are emitted in
    input order — async_stream's `:ordered: true` plus the runner's
    `:on_site_completed` sequential post-fold ensure a consumer
    concatenating the stream into the aggregate would reproduce
    `mutation.results[]` byte-equal to the standalone aggregate
    document's array. A run that aborts before the enumeration phase
    writes no stream lines, only the aggregate document. That covers
    CLI and report path errors, every host setup abort
    (mutagen.cli.r19), and scope, test selection, AST cache and coverage
    aborts. A run that aborts in enumeration or baseline, such as
    `too_many_sites` or `baseline_red`, writes only the end line.

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
      - On aborted (`aborted: true`) runs: `details` includes a fixed
        hint and stderr note. The default includes available phase facts
        such as step, file, line, module, reason atom, and counts.
        For example, a test_file_load_failed abort includes the test file,
        while a coverage timeout includes the configured deadline.
        With --include-host-output the report also includes the phase's
        sanitized diagnostic body if one is available.

    Leaf encoding: atom values are stringified (e.g. `kind: :scope` →
    `"kind": "scope"`); integer/boolean values pass through; binary
    leaves are sanitized through the r10 truncation + r11 redaction
    pipeline before emission. Map values may nest one layer deep
    (e.g. `failures: [...]` from baseline-red details).

    For `baseline_red`, `details.failures` holds the same objects as
    `baseline.failures`
    (mutagen.mutation_pipeline.r1), not inspected Elixir terms.

    Decision: mutagen.decision.details_always_present.

    Counter-example (pre-fix): a downstream user's `mix mutagen` aborts
    with `abort_reason: "test_file_load_failed"`. The default details
    give the file, exception module when available, and a fixed hint.
    The underlying diagnostic body is available with
    `--include-host-output`.

- id: mutagen.json_schema.r17
  priority: must
  statement: |
    Before truncation, the report redacts whole URL userinfo, credential
    query parameters, authorization and cookie headers, recognized token
    prefixes, JWTs and PEM keys. Secret assignments, tuples, keyword lists
    and inspected JSON redact the entire credential value, including nested
    terms. Keys are recognized by case-insensitive segments, including
    camelCase boundaries. Cleaning an already-cleaned field with the built-in
    rules leaves it unchanged. These rules apply to opted-in host output and
    structured strings such as test names and filter values.


- id: mutagen.json_schema.r18
  priority: must
  statement: |
    Aggregate results and matching NDJSON lines cap source excerpts and remove
    non-formatting control characters. The source-free mode omits source excerpts, file and function
    from site entries. Compile errors carry the same mutator confidence as
    results, and carry the function when source is included.

- id: mutagen.json_schema.r19
  priority: must
  statement: |
    The default report omits runtime-derived text bodies, including captured
    stderr, exceptions and host compile output. The host-output option includes
    these bodies after redaction and truncation. The JSON boundary applies those
    rules once per field in both aggregate and NDJSON output. Abort documents
    carry a fixed hint and structured facts when available.

- id: mutagen.json_schema.r20
  priority: must
  statement: |
    The abort_reason type in JsonReporter lists the reportable reason atoms.
    A report abort emits the matching string and returns exit code 2.

- id: mutagen.json_schema.r21
  priority: must
  statement: |
    When a binary operator has a literal left operand and the parser does not
    record the start of that operand, before_source uses the rendered AST
    instead of emitting a slice starting at the operator.

- id: mutagen.json_schema.r22
  priority: must
  statement: |
    Default documents and stream lines apply the field provenance table.
    Host process names, dynamic exception names, test names, and helper
    filter values are opt-in. Unknown default reason atoms become host_reason.
    Exception locations come from repository stack frames, relative to the root.

- id: mutagen.json_schema.r23
  priority: must
  statement: |
    Credential redaction examines at most 64 KiB per field before the 4 KiB
    payload cap. A regex execution error discards the field and replaces it
    with the fixed redaction-failure marker.

- id: mutagen.json_schema.r24
  priority: must
  statement: |
    Source excerpts omit Unicode format characters, including bidi and
    zero-width characters.
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
    - "The document has `version: \"2\"`, `aborted: false`, `abort_reason: null`."
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
    - "`version: \"2\"`, `aborted: true`, `abort_reason: \"missing_scope\"`."
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
    - "Decoding succeeds. The decoded map's `:version` key (or `\"version\"`) equals `\"2\"`."
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
    - An opted-in pipeline run that aborts with a `details.message` of 10_240 bytes (over the 4 KiB r10 cap).
  when:
    - "`JsonReporter.emit_error/2` renders the error document."
  then:
    - "The decoded JSON's `details.message` is exactly 4096 bytes of payload followed by ` ... <6144 bytes truncated>`."
    - The sanitizer pipeline applied to abort-detail string leaves matches the sanitizer applied to `mutation.results[].warnings[]`.

- id: mutagen.json_schema.s17
  covers:
    - mutagen.json_schema.r4
    - mutagen.json_schema.r14
  given:
    - "Forty results: each of the ten registered mutators crossed with `killed`, `survived`, `timeout` and `error`."
  when:
    - "`JsonReporter.emit_report/1` renders the aggregate and `JsonStreamer.emit_result/2` streams each result."
  then:
    - "Every aggregate entry carries `confidence`: `\"low\"` for `with_swap`, `pipeline`, and `guard_drop` and `\"high\"` for the other seven mutators, for every status."
    - "Each NDJSON result line equals its aggregate entry plus `kind` and `version`."

- id: mutagen.json_schema.s14b
  covers:
    - mutagen.json_schema.r14
  given:
    - "A user runs `mix mutagen --stream` and scope resolution aborts."
  when:
    - The task emits the abort.
  then:
    - "Stdout holds no NDJSON line. The aggregate document is the only output."

- id: mutagen.json_schema.s14c
  covers:
    - mutagen.json_schema.r14
  given:
    - "A user runs `mix mutagen --stream` and the enumerator aborts with `too_many_sites`."
  when:
    - The task emits the abort.
  then:
    - "Stdout holds one NDJSON line, of kind `end`, with `aborted: true`, `abort_reason: \"too_many_sites\"` and `meta.id_scheme: \"2\"`."
    - "No `start` line is written."

- id: mutagen.json_schema.s18
  covers:
    - mutagen.json_schema.r17
    - mutagen.json_schema.r11
  given:
    - 'An abort report whose `details` is `%{password: "p-one", nested: [%{message: "password: p-two"}]}` and whose `tests.exclude` holds `{:token, "p-three"}` and `{:foo, [:a]}`.'
    - 'A configured redaction pattern `"custom"`.'
  when:
    - '`JsonReporter.emit_error/2` renders the report, and `Sanitizer.clean("password=hunter2 custom example")` runs.'
  then:
    - 'The JSON contains none of `p-one`, `p-two`, or `p-three`. `details.password` is `"[REDACTED]"`, and `tests.exclude` is `["foo:[:a]", "token:[REDACTED]"]`.'
    - 'The clean call returns `"password=[REDACTED] [REDACTED] example"`.'

- id: mutagen.json_schema.s19
  covers:
    - mutagen.json_schema.r17
  given:
    - "The keys `DATABASE_PASSWORD`, `db_password`, `api-token`, `secret_key_base`, and `AWS_SECRET_ACCESS_KEY`, each in an inspected keyword list, an inspected map, an environment assignment, and a URL query."
    - "An abort report with `details` `%{database_password: v}` and an exclude filter `{:\"api-token\", v}`."
  when:
    - "`Sanitizer.clean/1` cleans each message and `JsonReporter.emit_error/2` renders the report."
  then:
    - "Every value is `[REDACTED]`, and cleaning the result again changes nothing."
    - "`tokens: 3, secretary: ann, primary_key: 7` comes back unchanged."
    - "`details.database_password` is `\"[REDACTED]\"` and `tests.exclude` is `[\"api-token:[REDACTED]\"]`."
```

```spec-verification
- kind: tagged_tests
  target: test/mutagen_ex
  covers:
    - mutagen.json_schema.r1
    - mutagen.json_schema.r2
    - mutagen.json_schema.r3
    - mutagen.json_schema.r4
    - mutagen.json_schema.r5
    - mutagen.json_schema.r6
    - mutagen.json_schema.r7
    - mutagen.json_schema.r8
    - mutagen.json_schema.r9
    - mutagen.json_schema.r10
    - mutagen.json_schema.r11
    - mutagen.json_schema.r12
    - mutagen.json_schema.r13
    - mutagen.json_schema.r14
    - mutagen.json_schema.r15
    - mutagen.json_schema.r16
    - mutagen.json_schema.r17
    - mutagen.json_schema.r18
    - mutagen.json_schema.r19
    - mutagen.json_schema.r20
    - mutagen.json_schema.r21
    - mutagen.json_schema.r22
    - mutagen.json_schema.r23
    - mutagen.json_schema.r24
```

## Default string provenance

Static JSON keys are schema constants. The table uses `[]` for an array
element and `{}` for a dynamic map entry. NDJSON result and compile
error lines reuse their aggregate fields. The start and end lines reuse
the envelope fields and add `kind`.

| Field | Origin | Default treatment |
| --- | --- | --- |
| `version` | Mutagen schema constant | Keep |
| `kind` | Mutagen stream discriminator | Keep |
| `meta.id_scheme` | Mutagen ID scheme constant | Keep |
| `meta.tool_version` | Mutagen build | Keep |
| `meta.elixir_version` | Runner toolchain | Keep |
| `meta.otp_version` | Runner toolchain | Keep |
| `scope[].file` | Repository or CLI path | Keep |
| `scope[].module` | Repository module declaration | Keep |
| `tests.files[]` | Repository or CLI path | Keep |
| `tests.include[]` | CLI selector or host helper | Keep CLI strings. Keep literal helper tag keys. Use the fixed token `host tag` for other helper keys. Omit helper values. |
| `tests.exclude[]` | CLI selector or host helper | Same filter policy as include |
| `tests.include[].kind` | Mutagen location discriminator | Keep |
| `tests.include[].file` | CLI location | Keep |
| `tests.exclude[].kind` | Mutagen location discriminator | Keep |
| `tests.exclude[].file` | CLI location | Keep |
| `coverage.covered_lines{key}` | Repository path | Keep |
| `baseline.failures[].module` | Repository test module | Keep with a failure count |
| `mutation.results[].id` | Source path, MD5 of normalized source AST, mutator | Keep |
| `mutation.results[].file` | Repository path | Keep with source enabled |
| `mutation.results[].function` | Repository definition | Keep with source enabled |
| `mutation.results[].before` | Repository AST | Strip controls and Unicode format characters. Cap. Omit with source disabled. |
| `mutation.results[].before_source` | Repository slice or AST | Same treatment as before |
| `mutation.results[].after` | AST produced from repository source | Same treatment as before |
| `mutation.results[].mutator` | Mutagen catalog | Keep |
| `mutation.results[].confidence` | Mutagen catalog | Keep |
| `mutation.results[].status` | Mutagen verdict vocabulary | Keep |
| `mutation.results[].warnings[]` | Mutagen text, repository references, or host diagnostics | Keep tool warnings. Render host-derived names as counts. Omit host bodies. |
| `mutation.compile_errors[].id` | Source path, MD5 of normalized source AST, mutator | Keep |
| `mutation.compile_errors[].file` | Repository path | Keep with source enabled |
| `mutation.compile_errors[].function` | Repository definition | Keep with source enabled |
| `mutation.compile_errors[].mutator` | Mutagen catalog | Keep |
| `mutation.compile_errors[].confidence` | Mutagen catalog | Keep |
| `mutation.compile_errors[].diagnostic` | Mutagen constant | Keep with source enabled |
| `mutation.compile_errors[].exception` | Exception type | Keep OTP, Elixir, dependency, and compiled project names. Compiled project names are repository text. Use `host exception` for other names. |
| `mutation.skipped[].site_id` | Source path, MD5 of normalized source AST, mutator | Keep |
| `mutation.skipped[].file` | Repository path | Keep |
| `mutation.skipped[].reason` | Mutagen enumeration vocabulary | Keep |
| `mutation.skipped[].mutator` | Mutagen catalog | Keep |
| `mutation.state_drift_warning{key}` | Repository module declaration | Keep |
| `mutation.state_drift_warning{}[]` | Repository use directive | Keep |
| `warnings[]` | Mutagen text plus repository paths, IDs, modules, app names, or runtime names | Keep tool warnings. Render host-derived names as counts. Omit host bodies. Deduplicate. |
| `abort_reason` | Mutagen abort vocabulary | Keep |
| `details.flag` | CLI flag | Keep |
| `details.file` | CLI or repository path, or a repository stack frame on raise | Keep repository stack frames relative to root. Omit missing or unverifiable frames. |
| `details.origin_file` | Repository stack frame | Keep relative to root |
| `details.module` | CLI argument or repository module | Keep |
| `details.exception` | Exception type | Same provenance policy as compile error exception |
| `details.reason` | Mutagen abort vocabulary or host reason | Keep known atoms. Replace other reasons with `host_reason`. |
| `details.site_id` | Source path, MD5 of normalized source AST, mutator | Keep |
| `details.phase` | Mutagen phase name | Keep |
| `details.step` | Mutagen step name | Keep |
| `details.hint` | Mutagen constant | Keep |
| `details.note` | Mutagen constant | Keep |
| `details.failures[].module` | Repository test module | Keep with a failure count |
| `details.include[]` | CLI selector or host helper | Same filter policy as tests include |
| `details.include[].kind` | Mutagen location discriminator | Keep |
| `details.include[].file` | CLI location | Keep |
| `details.exclude[]` | CLI selector or host helper | Same filter policy as tests exclude |
| `details.exclude[].kind` | Mutagen location discriminator | Keep |
| `details.exclude[].file` | CLI location | Keep |

With `--include-host-output`, the report can also carry diagnostic bodies
in `details.message`, compile errors, and warnings. It can include actual
test names, helper filters, host warning names, and dynamic reason and
exception names. Pattern redaction is best-effort.
