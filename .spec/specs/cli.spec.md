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
    syntax dropped, and self-mutation refused.
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
```

```spec-verification
- id: mutagen.cli.v1
  covers: [mutagen.cli.r1, mutagen.cli.r2, mutagen.cli.r3, mutagen.cli.r4, mutagen.cli.r5]
  kind: command
  command: mix test test/mutagen_ex/cli_test.exs
  execute: false

- id: mutagen.cli.v2
  covers: [mutagen.cli.r6, mutagen.cli.r7]
  kind: command
  command: mix test test/mutagen_ex/cli_test.exs --only exit_codes
  execute: false

- id: mutagen.cli.v3
  covers: [mutagen.cli.r8]
  kind: command
  command: mix test test/mutagen_ex/end_to_end_test.exs --only self_mutation
  execute: false

- id: mutagen.cli.v4
  covers: [mutagen.cli.r9]
  kind: command
  command: mix help mutagen
  execute: false
```
