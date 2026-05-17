# mutagen.cli — `mix mutagen` command-line contract

The user-facing surface of `mutagen_ex`. `mix mutagen` is the only entry point:
it parses flags, validates them, hands off to the orchestration pipeline, and
emits a single JSON document to stdout (or to `--json <path>` if requested).

## Intent

The verifier judge (an LLM downstream) consumes the JSON; humans invoke the
tool to spot-check that judge's reasoning. The CLI is therefore a stable
machine surface first, a human surface second. Flag semantics, exit codes, and
output discipline are part of the contract — changes here ripple to the judge
prompt and to every CI integration.

## Out of scope for this subject

- The mutation algorithm itself (see [mutagen.mutators](mutators.spec.md)).
- The orchestration state machine (see
  [mutagen.mutation_pipeline](mutation_pipeline.spec.md)).
- The JSON output schema (see [mutagen.json_schema](json_schema.spec.md)).
  This subject only asserts that the CLI **emits** the schema's documents at
  the right moments.

```spec-meta
id: mutagen.cli
kind: module
status: draft
summary: Parses CLI flags, validates them, and gates entry into the pipeline; owns exit-code discipline.
surface:
  - lib/mix/tasks/mutagen.ex
  - lib/mutagen_ex/cli.ex
  - lib/mutagen_ex/config.ex
  - lib/mutagen_ex/types.ex
decisions:
  - mutagen.decision.serial_execution_and_seed
  - mutagen.decision.no_pretty_output_v1
  - mutagen.decision.scope_syntax_simplified
  - mutagen.decision.self_mutation_refused
  - mutagen.decision.preamble_in_run1_only
```

```spec-requirements
- id: mutagen.cli.r1
  priority: must
  statement: |
    `mix mutagen` accepts `--scope <target>` (required, repeatable) where each
    target is a file path, a module name, or `Module.fun/arity`. Targets are
    accumulated into a list on `%Config{}`. If `--scope` is omitted, the task
    exits with an error-JSON document (per mutagen.json_schema) and a non-zero
    exit code.

- id: mutagen.cli.r2
  priority: must
  statement: |
    `mix mutagen` accepts `--tests <target>` (required, repeatable) where each
    target is a file path, a `file:line` pair, or `tag:<name>`. Targets are
    accumulated into a list on `%Config{}`. If `--tests` is omitted, the task
    exits with an error-JSON document and a non-zero exit code.

- id: mutagen.cli.r3
  priority: must
  statement: |
    `--timeout-ms <n>` populates `Config.timeout_ms` as a positive integer.
    Default is 5000. Non-positive or non-integer values cause an error-JSON
    exit before any pipeline phase runs.

- id: mutagen.cli.r4
  priority: must
  statement: |
    `--seed <n>` populates `Config.seed` and is propagated to
    `ExUnit.configure(seed: n)` for every test-running phase. Default is 0.
    Per mutagen.decision.serial_execution_and_seed, the seed governs ExUnit
    test ordering only — mutation enumeration order is independent of the
    seed.

- id: mutagen.cli.r5
  priority: must
  statement: |
    `--json <path>` writes the final JSON document to `<path>` instead of
    stdout. If the flag is absent, the document is written to stdout. In
    either case the document is terminated by a single newline.

- id: mutagen.cli.r6
  priority: must
  statement: |
    `mix mutagen` exits 0 on successful completion (pipeline ran to the end,
    even if every mutation survived). Non-zero exits are reserved for "bad
    input" cases: unparseable flags, unresolvable scope, no tests match, red
    baseline, or unrecoverable pipeline errors. Every non-zero exit also
    emits an error-JSON document.

- id: mutagen.cli.r7
  priority: must
  statement: |
    `--no-json` is not a recognised flag in v1. If supplied, `mix mutagen`
    exits with an error-JSON document explaining that pretty terminal output
    is deferred to v1.1.

- id: mutagen.cli.r8
  priority: must
  statement: |
    `mix mutagen` refuses to run if any `--scope` target resolves to a module
    in the `MutagenEx.*` or `Mix.Tasks.Mutagen` namespace, per
    mutagen.decision.self_mutation_refused. The error-JSON `reason` field is
    `:self_mutation_refused`.

- id: mutagen.cli.r9
  priority: should
  statement: |
    The `mix help mutagen` output contains a Synopsis, Flags, Examples,
    Constraints, Exit Codes, and Known Caveats section. The Caveats section
    enumerates: state drift on `use SomeModule`, macro mutation slowdown,
    equivalent mutants, mix-format ID-stability via content-addressed IDs,
    no `--no-json` in v1, `--seed` controls ExUnit ordering, scope colon
    syntax dropped, self-mutation refused, the `--json` path-safety
    contract (r10), and the `tag:NAME` charset gate (r11).

- id: mutagen.cli.r10
  priority: must
  statement: |
    `--json <path>` is canonicalised before any mutation phase runs. The
    path-safety contract has two layers:

      1. Pure-string checks at parse time. A `--json` value containing a
         NUL byte (`\0`) or any `..` segment is refused with an error-JSON
         document whose `abort_reason` is `"unsafe_json_path"`. No mutation
         phase runs.
      2. Filesystem canonicalisation before the first mutation phase.
         Every existing component of the path is resolved through
         `File.read_link/1`. If any symlink target escapes the project
         root (defined as `File.cwd!/0` resolved through `Path.expand/1`),
         the run aborts with `abort_reason: "unsafe_json_path"`. The
         final component is allowed to not yet exist — it is created at
         write time. After canonicalisation, the resolved absolute path
         is stored on `Config.json_path`.

    The default policy is: the resolved path MUST live inside the project
    root. Passing `--unsafe-json-outside-project` opts out of that check
    (the symlink-escape check still runs at every component, but the
    inside-root check is bypassed). When the flag is set, `mix mutagen`
    emits a one-shot warning to stderr at startup naming the resolved
    target path. `Config.unsafe_json_outside_project` is `true` iff the
    flag was passed.

- id: mutagen.cli.r11
  priority: must
  statement: |
    `--tests tag:NAME` targets are validated at parse time against the
    charset `~r/\A[a-z][a-z_0-9]{0,63}\z/`: NAME must start with `a-z` and
    consist of `a-z`, `0-9`, or `_` thereafter, up to 64 characters total.
    Targets that fail the regex return `{:error, :invalid_tag_name, %{flag:
    "--tests", target: "tag:<bad>", message: ...}}` from `CLI.parse/1`
    before any test selector resolution runs. This is the front-door bound
    for the atom-table-DOS risk (mutagen-wrd.20): even with a downstream
    string-comparison fallback in `mutagen.test_selection` (r7), the
    charset gate keeps adversarial CI loops (`mix mutagen --tests
    tag:$(uuidgen)`) from reaching the resolver at all. Non-`tag:` `--tests`
    targets (file paths, `file:line`) are not gated by this rule — they
    don't feed atom resolution.

- id: mutagen.cli.r12
  priority: must
  statement: |
    Resource caps protect the runtime from runaway input shapes (closes
    F28 / CF11 — security M1, performance F-PERF-07/12):

      1. `--scope` accepts at most 100 occurrences. The 101st occurrence
         is refused at parse time with `reason: :too_many_targets`. The
         error-JSON `details` map carries `flag: "--scope"`, `kind:
         :scope`, `cap: 100`, and `count: <n>`. The cap is structural
         — enforced before any scope resolution. The `tag:NAME` charset
         gate (r11) runs before this cap, so invalid tag names are
         rejected at parse time regardless of count.
      2. `--tests` accepts at most 100 occurrences with the same shape
         (`flag: "--tests"`, `kind: :tests`).
      3. `--max-sites <n>` populates `Config.max_sites` as a positive
         integer. Default 10_000. Non-positive or non-integer values
         cause an error-JSON exit with `reason: :invalid_max_sites`
         before any pipeline phase runs.

    The `--max-sites` cap is enforced inside the mutation enumerator
    (see `mutagen.mutation_enumeration.r7`); the cap value flows from
    `Config.max_sites` through the orchestrator. Exceeding it aborts
    the pipeline with `abort_reason: "too_many_sites"` before the
    mutation runner starts.

- id: mutagen.cli.r13
  priority: must
  statement: |
    `--budget-ms <n>` populates `Config.budget_ms` as an optional
    positive integer aggregate wall-clock budget for the mutation
    phase, in milliseconds. Absence leaves `Config.budget_ms == nil`,
    which means unbounded — the per-site `--timeout-ms` is still the
    only cap.

    When the budget elapses, the mutation runner stops dispatching
    further sites and returns the partial result it has accumulated.
    The final JSON document on stdout (or `--json <path>`) carries
    `truncated: true` at the top level and the `mutation` block
    reflects only the completed sites. `aborted` stays `false` —
    truncation is a graceful early exit, not an abort.

    The runner does NOT interrupt an in-flight site; the worst-case
    overshoot is one `timeout_ms`. Non-positive or non-integer
    `--budget-ms` values cause an error-JSON exit with `reason:
    :invalid_budget_ms`.

- id: mutagen.cli.r14
  priority: must
  statement: |
    Before the first pipeline phase runs, `mix mutagen` ensures the host
    project's modules are loaded into the BEAM, the `:ex_unit` application
    is started, and the `:mutagen_ex` application is started. Concretely,
    `Mix.Tasks.Mutagen.run/1` invokes (in order):

      1. `Mix.Task.run("loadpaths")` — adds the host project's
         `_build/<env>/lib/<app>/ebin` to `:code` paths so
         `:code.which/1` can locate scope modules.
      2. `Mix.Task.run("compile")` — compiles the host project (no-op
         when already compiled).
      3. `Application.ensure_all_started(:mutagen_ex)` — boots
         `MutagenEx.Application` so `MutagenEx.TaskSup` is alive when
         `MutationLoop` dispatches per-site tasks (see
         [mutagen.mutation_pipeline](mutation_pipeline.spec.md) and
         mutagen.decision.supervision_tree).
      4. `ExUnit.start(autorun: false)` — starts the `:ex_unit`
         application so cited test files (which `use ExUnit.Case`) can
         load. `autorun: false` is critical: `CoverageRunner`,
         `Baseline`, and `MutationLoop` each drive `ExUnit.run/0`
         themselves per the in-process pipeline contract.

    Without this preamble, a downstream caller invoking `mix mutagen`
    from a fresh shell against their own project aborts with
    `:module_beam_missing` (modules not loaded), `:test_file_load_failed`
    (ExUnit not started, raising `cannot use ExUnit.Case without
    starting the ExUnit application`), or a no-process crash on
    `MutagenEx.TaskSup` (`:mutagen_ex` application not started).

    The preamble lives in `run/1` ONLY. `run/2` (the documented test
    seam) stays preamble-free per
    mutagen.decision.preamble_in_run1_only. The existing test suite
    drives the Mix task via `run/2` from inside an already-running
    `mix test` invocation; running the preamble again would risk
    double-compile and ExUnit ordering conflicts.

    Library callers invoking `MutagenEx.MutationRunner.run/1` directly
    (the documented library entry per `README.md`) are responsible for
    ensuring `:mutagen_ex` is started themselves. The library entry is
    NOT in this requirement's surface — `r14` covers the CLI entry only.

- id: mutagen.cli.r15
  priority: must
  statement: |
    When `--json <path>` is refused under r10's path-safety contract
    (either the parse-time `..`/NUL pure-string check or the filesystem
    canonicalisation symlink-escape check), the error-JSON document
    does NOT land at the rejected path. It is written to stdout
    instead. This refines r10: the safety check rejects the path
    semantically AND ensures no write touches the rejected target.

    Implementation: when the json-path validation phase returns
    `{:abort, _report, _config, :unsafe_json_path, _details}`, the
    abort emission path MUST clear `Config.json_path` (set to `nil`)
    before invoking the IO sink. Downstream IO routing keys on
    `json_path: nil` to emit to stdout per r5.

    Counter-example (pre-fix bug): a user runs
    `mix mutagen --json /tmp/foo.json` outside the project root with
    no `--unsafe-json-outside-project`. r10 correctly rejects with
    `abort_reason: "unsafe_json_path"`, but the error JSON is then
    written to `/tmp/foo.json` anyway — undermining the safety
    guarantee a downstream consumer relies on. The fix is mandatory:
    the rejected path must not be written to under any abort variant.
```

```spec-scenarios
- id: mutagen.cli.s1
  covers: [mutagen.cli.r1, mutagen.cli.r2]
  given: A user invokes `mix mutagen --scope lib/foo.ex --tests test/foo_test.exs`.
  when: The CLI parses these flags.
  then: |
    `%Config{}` has `scopes: ["lib/foo.ex"]` and `tests: ["test/foo_test.exs"]`
    and the pipeline is invoked with that struct.

- id: mutagen.cli.s2
  covers: [mutagen.cli.r1]
  given: A user invokes `mix mutagen --tests test/foo_test.exs` without `--scope`.
  when: The CLI parses these flags.
  then: |
    No pipeline phase runs. An error-JSON document with `reason:
    :missing_scope` is emitted to stdout, and the task exits with a non-zero
    code.

- id: mutagen.cli.s3
  covers: [mutagen.cli.r1, mutagen.cli.r2]
  given: A user invokes `mix mutagen --scope MutagenEx.Foo.bar/1 --scope lib/baz.ex --tests tag:fast`.
  when: The CLI parses these flags.
  then: |
    `%Config{}` has `scopes: ["MutagenEx.Foo.bar/1", "lib/baz.ex"]` and
    `tests: ["tag:fast"]`. Repeat occurrences of `--scope` accumulate; they
    do not overwrite each other.

- id: mutagen.cli.s4
  covers: [mutagen.cli.r3]
  given: A user invokes `mix mutagen --timeout-ms 0 ...`.
  when: The CLI parses these flags.
  then: |
    An error-JSON document with `reason: :invalid_timeout` is emitted.
    `Config.timeout_ms` is never set to 0.

- id: mutagen.cli.s5
  covers: [mutagen.cli.r4]
  given: A user invokes `mix mutagen --seed 42 ...`.
  when: The pipeline runs.
  then: |
    `ExUnit.configure(seed: 42)` is called before the baseline test run,
    before the coverage test run, and before each mutation test run. The
    final JSON document's `meta.exunit_seed` field is `42`.

- id: mutagen.cli.s6
  covers: [mutagen.cli.r6]
  given: |
    A run completes the full pipeline; every mutation survived (kill rate 0.0).
  when: The task finishes.
  then: |
    Exit code is 0. The JSON document on stdout has `aborted: false` and a
    populated `mutation` block.

- id: mutagen.cli.s7
  covers: [mutagen.cli.r6]
  given: |
    A user invokes `mix mutagen --scope lib/foo.ex --tests test/foo_test.exs`
    but the baseline test run has failing tests.
  when: The baseline phase reports red.
  then: |
    Exit code is non-zero. The JSON document has `aborted: true` and
    `abort_reason` names the red baseline; no mutation phase runs.

- id: mutagen.cli.s8
  covers: [mutagen.cli.r7]
  given: A user invokes `mix mutagen --no-json --scope ... --tests ...`.
  when: The CLI parses these flags.
  then: |
    An error-JSON document with `reason: :flag_not_supported_in_v1` is
    emitted. Exit code is non-zero.

- id: mutagen.cli.s9
  covers: [mutagen.cli.r8]
  given: A user invokes `mix mutagen --scope MutagenEx.MutationRunner --tests ...`.
  when: The CLI resolves scope targets to modules.
  then: |
    An error-JSON document with `reason: :self_mutation_refused` is emitted
    before any mutation phase runs.

- id: mutagen.cli.s10a
  covers: [mutagen.cli.r10]
  given: A user invokes `mix mutagen --json ../../etc/passwd --scope ... --tests ...`.
  when: The CLI parses these flags.
  then: |
    `MutagenEx.CLI.parse/1` returns
    `{:error, :unsafe_json_path, %{variant: :traversal, ...}}`. No
    filesystem touch happens; an error-JSON document with
    `abort_reason: "unsafe_json_path"` is emitted to stdout. The file at
    the traversal target is never opened.

- id: mutagen.cli.s10b
  covers: [mutagen.cli.r10]
  given: |
    A user invokes `mix mutagen --json "out/report\0.json" --scope ...
    --tests ...` (NUL byte embedded in the path).
  when: The CLI parses these flags.
  then: |
    `MutagenEx.CLI.parse/1` returns
    `{:error, :unsafe_json_path, %{variant: :nul_byte, ...}}`. The error
    JSON is emitted; no mutation phase runs.

- id: mutagen.cli.s10c
  covers: [mutagen.cli.r10]
  given: |
    A symlink `<project_root>/escape.json` exists, pointing at `/etc/passwd`.
    The user invokes `mix mutagen --json escape.json ...`.
  when: The canonicalisation phase resolves the path.
  then: |
    The phase aborts with `abort_reason: "unsafe_json_path"` and
    `details.variant == :outside_project_root`. `/etc/passwd` is never
    opened.

- id: mutagen.cli.s10d
  covers: [mutagen.cli.r10]
  given: |
    A symlink `<project_root>/in/inside.json` exists pointing at
    `<project_root>/out/report.json` (target stays inside project root).
    The user invokes `mix mutagen --json in/inside.json ...`.
  when: The canonicalisation phase resolves the path.
  then: |
    The phase returns `{:ok, "<project_root>/out/report.json"}`. The mutation
    pipeline writes the report to the resolved path.

- id: mutagen.cli.s10e
  covers: [mutagen.cli.r10]
  given: |
    A user invokes `mix mutagen --json /tmp/ci-artifacts/report.json
    --unsafe-json-outside-project --scope ... --tests ...`.
  when: The CLI parses and the canonicalisation phase resolves.
  then: |
    `Config.unsafe_json_outside_project` is `true`. The phase returns
    `{:ok, "/tmp/ci-artifacts/report.json"}` even though the path is
    outside the project root. A warning naming the resolved path is
    written to stderr exactly once.

- id: mutagen.cli.s11
  covers: [mutagen.cli.r11]
  given: A user invokes `mix mutagen --scope lib/foo.ex --tests tag:$(uuidgen)`.
  when: The CLI parses these flags.
  then: |
    The UUID's `-` characters (and possible uppercase hex) violate the
    `~r/\A[a-z][a-z_0-9]{0,63}\z/` charset. `CLI.parse/1` returns
    `{:error, :invalid_tag_name, _}` before the test selector runs.
    `Config` is not constructed; no atom is created from the UUID string.

- id: mutagen.cli.s11b
  covers: [mutagen.cli.r11]
  given: A user invokes `mix mutagen --scope lib/foo.ex --tests tag:slow`.
  when: The CLI parses these flags.
  then: |
    `Config.tests` is `["tag:slow"]`. `slow` matches the charset and
    flows through to test selection unchanged.

- id: mutagen.cli.s12a
  covers: [mutagen.cli.r12]
  given: |
    A user invokes `mix mutagen` with 101 distinct `--scope <target>`
    occurrences and one `--tests` target.
  when: The CLI parses these flags.
  then: |
    `MutagenEx.CLI.parse/1` returns
    `{:error, :too_many_targets, %{flag: "--scope", kind: :scope,
    cap: 100, count: 101, ...}}`. No filesystem touch, no scope
    resolution, no mutation phase. The error-JSON document's
    `abort_reason` is `"too_many_targets"`.

- id: mutagen.cli.s12b
  covers: [mutagen.cli.r12]
  given: |
    A scope/tests combination whose enumerated mutation sites exceed
    `Config.max_sites` (default 10_000), e.g. a broad `--scope` on a
    large module with thorough coverage.
  when: The enumerator phase runs.
  then: |
    The phase returns
    `{:error, :too_many_sites, %{cap: 10000, count: <n>, ...}}`. The
    pipeline aborts with `abort_reason: "too_many_sites"` BEFORE the
    mutation runner starts. The error-JSON document names the count
    so the user can decide whether to narrow `--scope` or raise
    `--max-sites`.

- id: mutagen.cli.s12c
  covers: [mutagen.cli.r12]
  given: A user invokes `mix mutagen --max-sites 0 ...`.
  when: The CLI parses these flags.
  then: |
    An error-JSON document with `reason: :invalid_max_sites` is
    emitted. `Config.max_sites` is never set to 0.

- id: mutagen.cli.s13a
  covers: [mutagen.cli.r13]
  given: |
    A user invokes `mix mutagen --budget-ms 1000 ...` against a scope
    whose enumerated mutation sites would take longer than 1000 ms in
    aggregate.
  when: The mutation phase runs and the budget elapses.
  then: |
    The runner stops dispatching new sites. The success-JSON document
    has `truncated: true` at the top level, `aborted: false`, and the
    `mutation` block holds only the completed sites' results. A
    `budget_exceeded` warning is included in the `warnings` array.

- id: mutagen.cli.s13b
  covers: [mutagen.cli.r13]
  given: A user invokes `mix mutagen --budget-ms 0 ...`.
  when: The CLI parses these flags.
  then: |
    An error-JSON document with `reason: :invalid_budget_ms` is
    emitted. `Config.budget_ms` is never set to 0.

- id: mutagen.cli.s14a
  covers: [mutagen.cli.r14]
  given: |
    A downstream project freshly cloned and installed with `mutagen_ex`
    as a dependency. A user invokes
    `mix mutagen --scope lib/foo.ex --tests test/foo_test.exs` from
    the project root in a fresh shell — no prior `mix test`, no IEx
    session, no manual preload.
  when: `Mix.Tasks.Mutagen.run/1` starts.
  then: |
    The preamble runs before any phase. After the preamble:
    `:code.which(Foo)` returns a charlist path (modules loaded);
    `Application.started_applications/0` includes both `:mutagen_ex`
    and `:ex_unit`; `Process.whereis(MutagenEx.TaskSup)` is a live PID.
    The coverage, baseline, and mutation phases then run normally and
    the document emitted has `aborted: false`.

- id: mutagen.cli.s14b
  covers: [mutagen.cli.r14]
  given: |
    The mutagen_ex test suite (`mix test`) is running. ExUnit drives
    a test that calls `Mix.Tasks.Mutagen.run/2` with a custom
    dispatch.
  when: `run/2` executes.
  then: |
    `run/2` does NOT invoke the preamble — no `Mix.Task.run("compile")`,
    no `ExUnit.start/1`, no `Application.ensure_all_started/1`. The
    test seam is preamble-free per
    mutagen.decision.preamble_in_run1_only.

- id: mutagen.cli.s15
  covers: [mutagen.cli.r15, mutagen.cli.r10]
  given: |
    A user invokes
    `mix mutagen --scope lib/foo.ex --tests test/foo_test.exs --json /tmp/foo.json`
    from a project whose root is `/Users/.../my_project`.
  when: `phase_json_path` runs.
  then: |
    The path is refused with `abort_reason: "unsafe_json_path"` per
    r10. The error-JSON document lands on stdout. No file is created
    at `/tmp/foo.json`. The exit code is non-zero per r6.
```

```spec-verification
- id: mutagen.cli.v1
  covers: [mutagen.cli.r1, mutagen.cli.r2, mutagen.cli.r3, mutagen.cli.r4, mutagen.cli.r5]
  kind: command
  command: mix test test/mutagen_ex/cli_test.exs
  execute: true

- id: mutagen.cli.v2
  covers: [mutagen.cli.r6, mutagen.cli.r7]
  kind: command
  command: mix test test/mutagen_ex/cli_test.exs --only exit_codes
  execute: true

- id: mutagen.cli.v3
  covers: [mutagen.cli.r8]
  kind: command
  command: mix test test/mutagen_ex/end_to_end_test.exs --only self_mutation
  execute: false

- id: mutagen.cli.v4
  covers: [mutagen.cli.r9]
  kind: command
  command: mix help mutagen
  execute: true

- id: mutagen.cli.v5
  covers: [mutagen.cli.r10]
  kind: command
  command: mix test test/mutagen_ex/json_path_test.exs test/mutagen_ex/cli_test.exs
  execute: true

- id: mutagen.cli.v6
  covers: [mutagen.cli.r11]
  kind: command
  command: mix test test/mutagen_ex/cli_test.exs --only tag_charset
  execute: true

- id: mutagen.cli.v7
  covers: [mutagen.cli.r12]
  kind: command
  command: mix test test/mutagen_ex/cli_test.exs test/mutagen_ex/mutation_enumerator_test.exs
  execute: true

- id: mutagen.cli.v8
  covers: [mutagen.cli.r13]
  kind: command
  command: mix test test/mutagen_ex/mutation_runner_test.exs test/mutagen_ex/cli_test.exs
  execute: true

- id: mutagen.cli.v9
  covers: [mutagen.cli.r14]
  kind: command
  command: mix test test/integration/downstream_adoption_test.exs --include integration
  execute: false

- id: mutagen.cli.v10
  covers: [mutagen.cli.r15]
  kind: command
  command: mix test test/mix/tasks/mutagen_test.exs --only unsafe_json_path
  execute: true
```
