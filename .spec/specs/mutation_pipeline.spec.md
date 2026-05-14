# mutagen.mutation_pipeline — baseline + per-mutation execution

Owns the two test-running phases that come after coverage: the baseline run
(does the cited test suite pass on unmutated code?) and the mutation loop
(for each site, swap → recompile → run → classify → restore). Every test run
in this subject is in-process per mutagen.decision.in_process_pipeline.

## Intent

This is the heart of the tool. The invariants are about correctness of the
in-process pipeline: timeouts must not leak named processes; classifications
must distinguish compile failures from genuine survivors; restore must be
bytecode-identical from the AST cache. State drift from `__using__/1` macros
is acknowledged as a known caveat rather than a crash condition, per
mutagen.decision.timeout_handling and the universal partial-report schema.

The `MutationLoop` helper is a private module inside the runner that owns
per-mutation timeout-wrapping, stdout suppression, and state snapshotting; it
is not a peer of the runner per mutagen.decision.mutation_loop_private.

## Out of scope for this subject

- Catalog of mutators (see [mutagen.mutators](mutators.spec.md)).
- Producing the JSON document (see [mutagen.json_schema](json_schema.spec.md)).

```spec-meta
id: mutagen.mutation_pipeline
kind: workflow
status: draft
summary: Baseline + per-mutation execution with timeout, restore, classification, and taint tracking.
surface:
  - lib/mutagen_ex/baseline.ex
  - lib/mutagen_ex/mutation_runner.ex
  - lib/mutagen_ex/mutation_runner/mutation_loop.ex
decisions:
  - mutagen.decision.in_process_pipeline
  - mutagen.decision.timeout_handling
  - mutagen.decision.serial_execution_and_seed
  - mutagen.decision.mutation_loop_private
  - mutagen.decision.self_mutation_refused
```

```spec-requirements
- id: mutagen.mutation_pipeline.r1
  priority: must
  statement: |
    `Baseline.run/1` executes the cited tests against unmutated code. If
    any test fails, the pipeline aborts with an error-shaped JSON whose
    `abort_reason` is `:baseline_red` and whose `baseline.failures[]` names
    each failing test (`{module, name}` pairs).

- id: mutagen.mutation_pipeline.r2
  priority: must
  statement: |
    Both `Baseline.run/1` and `MutationRunner.run/1` force
    `ExUnit.configure(max_cases: 1, seed: config.seed)`. Tests declared
    `async: true` are still run serially. If any cited test module was
    declared `async: true`, a warning naming that module is added to the
    JSON's `warnings` array.

- id: mutagen.mutation_pipeline.r3
  priority: must
  statement: |
    `MutationRunner.run/1` refuses to mutate modules whose name starts with
    `MutagenEx.` or matches `Mix.Tasks.Mutagen`. The pipeline aborts before
    any mutation runs with an error-shaped JSON `reason:
    :self_mutation_refused`, per mutagen.decision.self_mutation_refused.

- id: mutagen.mutation_pipeline.r4
  priority: must
  statement: |
    Per-mutation execution wraps `ExUnit.run/1` in a structure that
    enforces `Config.timeout_ms`. When the timeout fires, the test
    process is cancelled via the two-phase path documented in
    mutagen.decision.timeout_handling: a trappable `:shutdown` first,
    escalating to `Process.exit(:kill)` only if the task does not
    unwind inside a bounded grace window. The site is classified
    `:timeout` regardless of which phase actually cleared the task,
    and the next iteration's classification record carries
    `tainted_predecessors: true`. After a `:timeout` outcome the
    runner calls `:code.purge/1` on the site's scoped modules before
    restore, so a brutal-killed task cannot leave the Code.Server
    holding an orphaned per-module load lock for the next site.

- id: mutagen.mutation_pipeline.r5
  priority: must
  statement: |
    Per-mutation classification has exactly five outcomes:
    `:killed` (at least one cited test failed),
    `:survived` (all cited tests passed),
    `:timeout` (timed out before classification),
    `:compile_error` (Code.compile_quoted/1 raised on the swapped AST),
    `:error` (uncaught exception or unexpected return from the test runner).
    `:compile_error` outcomes are NOT counted in the kill-rate denominator;
    the others all are. A mutation whose surviving code raises an
    uncaught runtime exception that causes a cited test to fail
    classifies as `:killed`, not `:error` — `:error` is reserved for
    crashes inside the test runner itself, not crashes in the mutated
    user code that the test observably caught. (Canonical example: a
    `:case_drop` mutation against a guarded-recursive-base-case `case`
    raises `CaseClauseError` when recursion reaches the dropped value;
    the cited test fails; classification is `:killed`. See
    mutagen.mutators.r8.) The corollary: `:case_drop` is not a reliable
    trigger for `:timeout`. Tests or fixtures that need deterministic
    `:timeout` classification (per r4) must induce divergence by other
    means — e.g., `:arith` flipping a recursive descent so the
    recursion never approaches its base case.

- id: mutagen.mutation_pipeline.r6
  priority: must
  statement: |
    After each per-mutation test run (regardless of classification), the
    original module's bytecode is restored by `Code.compile_quoted/1` on
    the cached AST (passing the source file's real path as the `file`
    argument). On restore failure the pipeline aborts with an error-shaped
    JSON `reason: :unrecoverable_restore_failure`.

- id: mutagen.mutation_pipeline.r7
  priority: must
  statement: |
    Per mutagen.decision.timeout_handling, after each per-mutation test
    run the runner snapshots `length(Process.registered())`,
    `length(:ets.all())`, and `:persistent_term.info().count`. If any
    grew compared to the snapshot taken before that mutation, a warning is
    emitted and every subsequent mutation result has `tainted_predecessors:
    true` until pipeline end.

- id: mutagen.mutation_pipeline.r8
  priority: must
  statement: |
    For any in-scope module whose source AST contains a `use SomeModule`
    invocation, the runner emits a `mutation.state_drift_warning` for that
    module naming the `use`d modules. The warning is informational; the
    pipeline continues. This is the visible signal for
    mutagen.decision.in_process_pipeline's "restore is bytecode-identical,
    not side-effect-identical" caveat.

- id: mutagen.mutation_pipeline.r9
  priority: must
  statement: |
    Stderr written during per-mutation runs (e.g. compiler warnings) is
    captured via `ExUnit.CaptureIO.capture_io(:stderr, ...)` and attached
    to that mutation's `results[i].warnings` field. Stderr never leaks to
    the user's terminal during the run.

- id: mutagen.mutation_pipeline.r10
  priority: must
  statement: |
    The pipeline phases do not reload test modules between runs. Test files
    are loaded once via `Code.require_file/1` before baseline; subsequent
    runs against the same `ExUnit` module registry reuse the same loaded
    code. The known caveat: edits to test files mid-run are silently
    ignored. This caveat is documented in `mix help mutagen`.

- id: mutagen.mutation_pipeline.r11
  priority: must
  statement: |
    `MutationRunner.run/1` does not modify any file on disk. The working
    tree is byte-identical before and after the runner completes.
```

```spec-scenarios
- id: mutagen.mutation_pipeline.s1
  covers: [mutagen.mutation_pipeline.r1]
  given: |
    A cited test suite has one failing test before any mutation.
  when: `Baseline.run/1` executes.
  then: |
    The pipeline halts. The JSON has `aborted: true`, `abort_reason:
    "baseline_red"`, and `baseline.failures` contains an entry naming the
    failing test. No mutation phase runs.

- id: mutagen.mutation_pipeline.s2
  covers: [mutagen.mutation_pipeline.r3]
  given: |
    A scope target `--scope MutagenEx.MutationRunner` resolves to one of
    the tool's own modules.
  when: `MutationRunner.run/1` starts.
  then: |
    Run aborts before any compile. JSON `aborted: true`, `abort_reason:
    "self_mutation_refused"`.

- id: mutagen.mutation_pipeline.s3
  covers: [mutagen.mutation_pipeline.r4, mutagen.mutation_pipeline.r5]
  given: |
    A mutation creates a deterministic infinite loop in the mutated
    module (e.g., `:arith` flipping `count_down(n - 1)` to
    `count_down(n + 1)` so the recursion diverges from its base case).
    `Config.timeout_ms` is 1000.
  when: The mutation phase processes that site.
  then: |
    Approximately 1000ms after the test run begins, the site is classified
    `:timeout`. The next-iteration mutation result has
    `tainted_predecessors: true`. The runner continues to subsequent sites
    rather than aborting. Note: a `:case_drop` mutation that drops a
    recursion's base case does NOT produce `:timeout` in this scenario
    — it raises `CaseClauseError` on the first iteration that reaches
    the dropped value and classifies `:killed` (per r5 and
    mutagen.mutators.r8).

- id: mutagen.mutation_pipeline.s4
  covers: [mutagen.mutation_pipeline.r5]
  given: |
    A mutated module produces source that `Code.compile_quoted/1` refuses
    (rare: the mutator's `validate/1` should have caught it, but we accept
    discoveries at runtime).
  when: The mutation phase processes that site.
  then: |
    The site is classified `:compile_error`. The
    `mutation.compile_errors[]` array gets an entry. The kill rate
    denominator does NOT increase by this site.

- id: mutagen.mutation_pipeline.s5
  covers: [mutagen.mutation_pipeline.r6]
  given: |
    A successful mutation phase completes for a given site.
  when: The next site begins processing.
  then: |
    `:code.which(<the just-mutated module>)` returns the same path it
    returned before the mutation. The module's MD5 (via
    `<mod>.module_info(:md5)`) matches the original module's MD5 from
    before mutation.

- id: mutagen.mutation_pipeline.s6
  covers: [mutagen.mutation_pipeline.r7]
  given: |
    A mutation timeout leaves a named GenServer (or new ETS table)
    registered.
  when: The runner snapshots after that mutation.
  then: |
    A warning is emitted naming the new registered process or ETS table.
    Every mutation result subsequent to this one in `mutation.results[]`
    has `tainted_predecessors: true`.

- id: mutagen.mutation_pipeline.s7
  covers: [mutagen.mutation_pipeline.r8]
  given: |
    A scoped module's source contains `use GenServer`.
  when: That module is selected as a mutation target.
  then: |
    The JSON has `mutation.state_drift_warning` mentioning
    `[GenServer]` in the relevant module's record. The pipeline
    continues; the warning is non-fatal.

- id: mutagen.mutation_pipeline.s8
  covers: [mutagen.mutation_pipeline.r9]
  given: |
    A mutated module produces compiler warnings on stderr.
  when: The mutation runs.
  then: |
    The warnings appear in `mutation.results[i].warnings` of that site.
    No stderr line was written to the actual terminal.
```

```spec-verification
- id: mutagen.mutation_pipeline.v1
  covers:
    - mutagen.mutation_pipeline.r1
    - mutagen.mutation_pipeline.r2
  kind: command
  command: mix test test/mutagen_ex/baseline_test.exs
  execute: true

- id: mutagen.mutation_pipeline.v2
  covers:
    - mutagen.mutation_pipeline.r3
    - mutagen.mutation_pipeline.r4
    - mutagen.mutation_pipeline.r5
    - mutagen.mutation_pipeline.r6
    - mutagen.mutation_pipeline.r7
    - mutagen.mutation_pipeline.r8
    - mutagen.mutation_pipeline.r9
  kind: command
  command: mix test test/mutagen_ex/mutation_runner_test.exs
  execute: true

- id: mutagen.mutation_pipeline.v3
  covers:
    - mutagen.mutation_pipeline.r6
    - mutagen.mutation_pipeline.r11
  kind: command
  command: mix test test/mutagen_ex/integration/c1_test.exs
  execute: true

- id: mutagen.mutation_pipeline.v4
  covers: [mutagen.mutation_pipeline.r10]
  kind: command
  command: mix test test/mutagen_ex/integration/c2_test.exs
  execute: true
```
