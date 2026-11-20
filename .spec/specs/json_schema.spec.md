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
  - lib/mutagen_ex/report_summary.ex
  - lib/mutagen_ex/markdown_summary.ex
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
  - mutagen.decision.json_report_channel
  - mutagen.decision.escalation_outcomes
  - mutagen.decision.advisory_only
  - mutagen.decision.advisory_changed_code
  - mutagen.decision.changed_code_run
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
  CLI aggregates also carry `timings_ms` (r25).
- `scope`: array of resolved scope records.
- `tests`: resolved test filter (the `{include, exclude, files}` triple).
- `baseline`: `{passed: int, failed: int, failures: [{module, count}]}` or
  `null` if baseline never ran.
- `coverage`: `{covered_lines: %{file => [int]}}` or `null` if coverage never
  ran.
- `mutation`: full mutation block (see r3) or `null` if mutation phase never
  ran.
- `summary`: advisory verdict, counts, ranked findings and notes. The
  NDJSON end record carries the same summary. See r36 and r37.
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
    `before_source` (string, the verbatim slice of the cached source text
      at the site's byte span from mutagen.mutation_enumeration.r11,
      subject to the same output cleaning as the other source excerpts).
      Results without that span can use the AST start and the exclusive
      `end_line` and `end_column` from mutagen.mutation_enumeration.r8.
      If source or a verified slice is unavailable, `before_source` reuses
      the same binary as `before` (same reference under `:erts_debug.same/2`).
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
    parseable by `:json.decode/1`. Every stream envelope or per-site line carries:
      - `"version"` — the same literal `"2"` the aggregate document
        emits (`r1`).
      - `"kind"` — one of `"start"`, `"result"`, `"compile_error"`,
        `"end"`.
    The four kinds bracket the run from the enumeration phase on:
      - `"start"` fires once at mutation-phase entry; carries `total`
        (planned site count, every enumerated site that was not skipped)
        and `meta` (r2's meta block), omitting timings and final completeness.
      - `"result"` fires once per completed site (any of `killed`,
        `survived`, `timeout`, `error`); the line's wire shape MUST be
        byte-equal to the equivalent entry in the aggregate document's
        `mutation.results[]` array (`r4`), including `function` and
        `confidence`, plus the `"kind"` and `"version"` discriminators.
      - `"compile_error"` fires once per `:compile_error` site; the
        line's wire shape MUST be byte-equal to the equivalent entry
        in `mutation.compile_errors[]`.
      - `"end"` fires once at pipeline exit (success or abort) for
        every run that reached the enumeration phase; carries the start
        metadata, final completeness when applicable, and
        the aggregate counters (`total`, `completed`, `killed`,
        `survived`, `timeout`, `compile_error`, `kill_rate`)
        AND `aborted`, `abort_reason` and `truncated`. Its `total` is the aggregate
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
    `too_many_sites` or `baseline_red`, writes the end line before the
    aggregate. The final line on the sink is always the aggregate
    document and has no `kind` field.

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
    The reporter maintains the abort reason vocabulary and a fixed hint for
    every reason. The README and schema tables match the reporter's list.
    The list includes the changed-code reasons diff_unavailable and
    invalid_since_ref before the CLI wiring emits them.
    Test builds reject unregistered abort reasons, including values passed
    through variables. A registered abort emits its string and exit code 2.

- id: mutagen.json_schema.r21
  priority: must
  statement: |
    The reporter reparses each candidate excerpt and compares the AST with
    the site's original AST after removing metadata. If the slice is missing,
    invalid, or describes a different expression, before_source reuses
    the rendered original AST.

- id: mutagen.json_schema.r22
  priority: must
  statement: |
    Default documents and stream lines apply the field provenance table.
    Host process names, ETS table names, persistent term keys,
    dynamic exception names, test names, and helper filter values are
    opt-in. Unknown default reason atoms become host_reason.
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

- id: mutagen.json_schema.r25
  priority: must
  statement: |
    Every CLI aggregate document carries `meta.timings_ms` with
    non-negative integer milliseconds for `boot`, `coverage`,
    `baseline`, `mutation` and `total`. A phase that did not run is zero.
    A phase that returns an error reports the elapsed time up to the
    error. The total measures pipeline entry through report assembly,
    before encoding and output, and includes work between phases such as
    enumeration. Stream envelopes and per-site lines omit `timings_ms`.
    Elapsed timings and baseline-derived deadlines can vary between
    deterministic runs. Captured host output may contain timestamps,
    process identifiers or references.

- id: mutagen.json_schema.r26
  priority: must
  statement: |
    Every document records the effective mutation dispatch limit as
    `meta.max_concurrency`. Above 1, the document carries a fixed top-level
    warning that verdicts are unreliable in experimental parallel mode.

- id: mutagen.json_schema.r27
  priority: must
  statement: |
    For sites enumerated from source, `before_source` is the original text
    of the expression when the span can be verified under r21. This includes
    call receivers, field access, and expressions beside or within quoted
    text containing multi-codepoint graphemes. The aggregate and stream use
    the same renderer.
- id: mutagen.json_schema.r28
  priority: must
  statement: |
    Changed-code reports include the requested ref, resolved base and
    counts in meta.since. Incomplete paths have fixed reasons. A Git abort
    reports a fixed cause without command diagnostics. Evaluated sites
    carry scope reasons, and outstanding runtime sites are listed as
    uncovered or not_run.

- id: mutagen.json_schema.r29
  priority: must
  statement: |
    Auto reports include selected files with selection reasons, each
    escalation step's admitted files, cap and survivor counts, and each
    result's steps and killing step. Repository test paths follow the
    source flag.

- id: mutagen.json_schema.r30
  priority: must
  statement: |
    Every CLI aggregate records baseline duration and the effective
    per-mutant deadline, including runs that do not reach mutation. Each escalation step records its own baseline and
    deadline when it runs mutants. A verified before_source slice has a
    one-based excerpt_line at its first byte, omitted with --no-source.
    AST-rendered fallbacks have no excerpt_line.

- id: mutagen.json_schema.r31
  priority: must
  statement: |
    Changed-code reports have meta.complete and meta.incomplete_reasons.
    A report is incomplete when the run aborts, is truncated, or has
    incomplete inputs. Mutation time budget truncation adds
    mutation_budget_exhausted to meta.incomplete_reasons. The site cap
    abort adds too_many_sites. A non-aborting incomplete run exits 0.
    Changed ranges outside explicit scope appear separately in
    meta.since.out_of_scope. Changed ranges without runtime sites
    appear in meta.since.unmapped without making the run incomplete.
    The aggregate baseline describes the narrow pass. Each escalation step
    records its own baseline and uses null when no files ran. tests.files
    lists the narrow selection and files admitted in every escalation pass.
    A warning about no tests running is removed once escalation runs tests.
    Selected test paths follow the source flag. Group fingerprints stay
    internal to planning.

- id: mutagen.json_schema.r32
  priority: must
  statement: |
    Redaction of oversized text has bounded work after the input cap.
    A megabyte of adversarial text takes less than eight times the
    duration for the same capped prefix, measured in the same test.

- id: mutagen.json_schema.r33
  priority: must
  statement: |
    Every abort document, including the end record of an aborted stream,
    sets meta.complete to false and includes the abort reason in
    meta.incomplete_reasons.
- id: mutagen.json_schema.r34
  priority: must
  statement: |
    Each escalation step records the count of candidates dropped after a load
    attempt as dropped_after_load and the per-candidate baseline deadline as
    candidate_deadline_ms when a probe ran. Results decided in that step or
    later include selection.after_dropped_file when one or more files were
    dropped after a load attempt. Rejection warnings name repository paths
    and fixed reasons by default. With --no-source they show counts.
    Survivors with candidate files or mutant reruns skipped by the
    escalation time budget carry selection.escalation_incomplete: true and
    selection.escalation_incomplete_reason: escalation_budget_exhausted.
- id: mutagen.json_schema.r35
  priority: must
  statement: |
    An untracked-file limit abort names the configured root and explains that
    untracked files under it exceeded the limit and that ignoring the directory
    fixes it.

- id: mutagen.json_schema.r36
  priority: must
  statement: |
    The aggregate and stream end carry the same additive summary. Check
    first identifies a function with only uncovered sites in a changed-code
    run or at least three evaluated high-confidence sites with complete
    escalation evidence, no kill
    at any confidence and no rejected red test file that mentions the
    function. Uncovered or unevaluated sites yield partly_checked when
    the run is otherwise complete. A changed, uncovered line within
    an evaluated multi-line site also yields partly_checked. These lines
    include zero-hit lines and lines in the span of an uncovered site.
    Validator skips are counted separately from unevaluated mutants.
    A run with surviving sites never says nothing_to_check.
    Remaining high-confidence survivors are ranked by escalation
    completeness, provisional mutator order, file, line and ID.
    The report records the number omitted by the cap. Only a nonempty
    ranked list can yield worth_a_look. If every survivor is low-confidence,
    the unranked verdict is low_confidence_survivors. If the cap hides a
    nonempty ranking, the unranked verdict is unranked_survivors.
    Timeouts are unevaluated. Taint is counted as a note.
    Kills marked selection.after_dropped_file still count as kills and carry
    a run-level note with their count. Each step's dropped_after_load count
    contributes to the run's loaded-and-dropped file count. Per-function
    kill rates use only killed and surviving sites.

- id: mutagen.json_schema.r37
  priority: must
  statement: |
    Markdown shows the kill rate with the number of killed and surviving
    sites used in the calculation. Markdown renders the summary without host
    diagnostics. --no-source omits function names, file paths and excerpts
    from summary entries and uses opaque rerun references. The rendered
    summary describes incomplete evidence, unmapped lines, out-of-scope
    lines and skipped escalation files. It names --escalate-budget-ms
    when the escalation budget runs out and labels survivors with
    incomplete escalation as not fully escalated. Preexisting symlinks
    and submodules under a source root have distinct wording.
    It leads with a note naming test
    files that failed on the unmutated code. An abort replaces the
    summary with the fixed abort reason and hint. A single-line excerpt
    can show the full line before and after to distinguish repeated
    literals. A clean run renders two lines.
- id: mutagen.json_schema.r38
  priority: must
  statement: |
    When escalation uses more than half the run wall time, JSON summary notes
    and Markdown list each escalation step's elapsed milliseconds. These
    notes can vary between invocations and appear in both aggregate and
    stream summaries.

- id: mutagen.json_schema.r39
  priority: must
  statement: |
    `--json PATH` is the guaranteed report channel. The file contains exactly
    one JSON document, or NDJSON with `--stream`, regardless of host output.

    Without `--json`, Mutagen writes the report to stdout and routes the
    `:user` device and known console logger handlers to stderr. The VM can
    write directly to file descriptor 1, including when an OTP logger
    handler crashes. In-process I/O routing cannot intercept those writes.
    Use `--json PATH` and `--summary PATH` in CI.
    A report written to stdout emits one fixed stderr line naming
    `--json PATH` as the reliable form for scripts and CI.

- id: mutagen.json_schema.r40
  priority: must
  statement: |
    If at least three mutants time out and their combined wait occupies
    more than half the mutation phase wall time, the summary includes
    a mutation_timeouts_dominate note. Overlapping waits count once.
    Markdown suggests --timeout-ms or --budget-ms.

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
    - mutagen.json_schema.r21
  given:
    - A `%Report{}` fixture with N completed-mutation results.
    - Some results carry a valid byte span or legacy coordinates into cached source, and some spans select a different expression.
  when:
    - JsonReporter renders the results.
  then:
    - A slice that parses to the original expression matches the hand-cut source bytes.
    - Missing or invalid slices share the rendered original AST binary with before.
    - The renderer calls Macro.to_string/1 at most twice per result.

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
    - mutagen.json_schema.r25
    - mutagen.json_schema.r26
    - mutagen.json_schema.r27
    - mutagen.json_schema.r33
    - mutagen.json_schema.r34
    - mutagen.json_schema.r36
    - mutagen.json_schema.r37
    - mutagen.json_schema.r39
    - mutagen.json_schema.r40
- kind: tagged_tests
  target: test/integration/changed_run_test.exs
  covers:
    - mutagen.json_schema.r34
    - mutagen.json_schema.r35
    - mutagen.json_schema.r36
    - mutagen.json_schema.r37
```

## Default string provenance

Automatically selected test paths in `meta.tests_selected`,
`meta.escalation`, and `tests.files` follow the source flag.

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
| `summary.verdict` | Tool vocabulary | Keep |
| `summary.check_first[].kind` | Tool vocabulary | Keep |
| `summary.check_first[].file` | Project source path | Omit with --no-source |
| `summary.check_first[].function` | Source definition | Omit with --no-source |
| `summary.check_first[].example.id` | Content-addressed site ID | Use an opaque reference with --no-source |
| `summary.check_first[].example.file` | Project source path | Omit with --no-source |
| `summary.check_first[].example.function` | Source definition | Omit with --no-source |
| `summary.check_first[].example.mutator` | Tool mutator name | Keep |
| `summary.check_first[].example.before_source` | Source excerpt | Cap and omit with --no-source |
| `summary.check_first[].example.after` | Mutant source | Cap and omit with --no-source |
| `summary.check_first[].example.steps_run[]` | Tool step name | Keep |
| `summary.check_first[].example.rerun` | Fixed command with site selector and tool options | Use an opaque selector for source-free or rewritten IDs |
| `summary.worth_a_look[].id` | Content-addressed site ID | Use an opaque reference with --no-source |
| `summary.worth_a_look[].file` | Project source path | Omit with --no-source |
| `summary.worth_a_look[].function` | Source definition | Omit with --no-source |
| `summary.worth_a_look[].mutator` | Tool mutator name | Keep |
| `summary.worth_a_look[].before_source` | Source excerpt | Cap and omit with --no-source |
| `summary.worth_a_look[].after` | Mutant source | Cap and omit with --no-source |
| `summary.worth_a_look[].steps_run[]` | Tool step name | Keep |
| `summary.worth_a_look[].rerun` | Fixed command with site selector and tool options | Use an opaque selector for source-free or rewritten IDs |
| `summary.by_function[].file` | Project source path | Omit with --no-source |
| `summary.by_function[].function` | Source definition | Omit with --no-source |
| `summary.notes[].kind` | Tool vocabulary | Keep |
| `summary.notes[].step` | Tool escalation step | Keep |
| `summary.notes[].reason` | Tool escalation vocabulary | Keep |
| `summary.notes[].files[]` | Project test paths from discovery | Omit with --no-source |
| `meta.timings_ms` | Mutagen monotonic clock | Keep the integer durations in the aggregate |
| `meta.since.ref` | CLI ref | Keep after Git resolves it |
| `meta.since.base` | Verified Git object ID | Keep |
| `meta.incomplete_reasons[].path` | Repository path | Keep with source enabled |
| `meta.incomplete_reasons[].reason` | Git or runner failure vocabulary | Keep |
| `meta.tests_selected[].why` | Mutagen selection vocabulary | Keep |
| `meta.since.unmapped[].path` | Repository path | Keep with source enabled |
| `meta.since.unmapped[].kind` | Mutagen scope vocabulary | Keep |
| `meta.tests_selected[].path` | Repository path | Keep with source enabled |
| `meta.escalation[].files_added[]` | Repository path | Keep with source enabled |
| `meta.escalation[].step` | Mutagen escalation vocabulary | Keep |
| `mutation.results[].excerpt_line` | Verified repository slice start | Keep with source enabled |
| `mutation.results[].in_scope` | Mutagen scope vocabulary | Keep |
| `mutation.results[].selection.killed_at` | Mutagen selection step | Keep |
| `mutation.results[].selection.steps_run[]` | Mutagen selection steps | Keep |
| `mutation.results[].selection.escalation_incomplete_reason` | Mutagen escalation vocabulary | Keep |
| `mutation.compile_errors[].in_scope` | Mutagen scope vocabulary | Keep |
| `mutation.pending[].id` | Source path, MD5 of normalized source AST, mutator | Keep |
| `mutation.pending[].file` | Repository path | Keep with source enabled |
| `mutation.pending[].function` | Repository definition | Keep with source enabled |
| `mutation.pending[].mutator` | Mutagen catalog | Keep |
| `mutation.pending[].confidence` | Mutagen catalog | Keep |
| `mutation.pending[].reason` | Mutagen coverage and run vocabulary | Keep |
| `mutation.pending[].in_scope` | Mutagen scope vocabulary | Keep |
| `details.cause` | Git reader failure vocabulary | Keep |
| `details.root` | Configured repository root | Keep for an untracked-file limit abort |
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
| `warnings[]` | Mutagen text plus repository paths, IDs, modules, app names, or runtime names | Keep tool warnings. Report growth and counts for host state. Omit host names and bodies. Deduplicate. |
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
| `details.hint` | Mutagen text and, for an untracked-file limit, the configured root | Keep |
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

## Abort reasons

| `abort_reason` |
| --- |
| `arity_required` |
| `baseline_red` |
| `baseline_timeout` |
| `colon_syntax_unsupported` |
| `cover_already_running` |
| `cover_compile_failed` |
| `cover_module_unavailable` |
| `coverage_timeout` |
| `diff_unavailable` |
| `escalation_crashed` |
| `ex_unit_run_failed` |
| `file_not_found` |
| `file_read_failed` |
| `flag_not_supported_in_v1` |
| `function_not_found` |
| `host_app_start_failed` |
| `host_compile_failed` |
| `host_loadpaths_failed` |
| `host_setup_timeout` |
| `invalid_boot_timeout` |
| `invalid_budget_ms` |
| `invalid_input` |
| `invalid_line` |
| `invalid_max_concurrency` |
| `invalid_max_sites` |
| `invalid_mix_env` |
| `invalid_redact_config` |
| `invalid_seed` |
| `invalid_site` |
| `invalid_since_ref` |
| `invalid_summary_max` |
| `invalid_tag_name` |
| `invalid_target` |
| `invalid_timeout` |
| `missing_scope` |
| `missing_tests` |
| `module_beam_missing` |
| `module_not_found` |
| `no_tests_match` |
| `no_tests_run` |
| `parse_error` |
| `runtime_load_failed` |
| `self_mutation_refused` |
| `site_not_found` |
| `summary_path_conflict` |
| `summary_write_failed` |
| `test_alias_failed` |
| `test_file_load_failed` |
| `test_helper_load_failed` |
| `too_many_sites` |
| `too_many_targets` |
| `umbrella_root` |
| `unknown_flag` |
| `unrecognised_target` |
| `unrecoverable_restore_failure` |
| `unsafe_json_path` |
| `unsafe_summary_path` |
| `unsupported_elixir_version` |
| `unsupported_otp_version` |
