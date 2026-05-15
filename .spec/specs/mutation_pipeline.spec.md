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
  - mutagen.decision.supervision_tree
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
    Per-mutation execution wraps `ExUnit.run/1` in a per-site task
    spawned via `Task.Supervisor.async_nolink(MutagenEx.TaskSup, ...)`
    that enforces `Config.timeout_ms`. When the timeout fires, the
    task is cancelled via the two-phase path documented in
    mutagen.decision.timeout_handling and
    mutagen.decision.supervision_tree: a `Task.shutdown(task,
    cancel_grace_ms)` mailbox-drain window first (default 100 ms),
    followed by `Task.Supervisor.terminate_child(MutagenEx.TaskSup,
    task.pid)` to escalate and update the supervisor's child table.
    Both phases dispatch `Process.exit(_, :shutdown)`, which
    propagates through the task's link tree to descendant processes.
    The site is classified `:timeout` regardless of which phase
    cleared the task, and the next iteration's classification record
    carries `tainted_predecessors: true`. After a `:timeout` outcome
    the runner calls `:code.purge/1` on the site's scoped modules
    before restore, so a killed task cannot leave the Code.Server
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
    tree is byte-identical before and after the runner completes,
    asserted across at minimum:
      * `lib/**/*.{ex,exs}` — source surface.
      * `_build/**/*.{beam,app}` — compiled artifacts. The runner uses
        `Code.compile_quoted/2` in memory; .beam files on disk must
        not change.
      * `cover/**` — coverage reports. The runner does not write
        coverage output to disk.
      * Host project config: `mix.exs`, `mix.lock`, `.formatter.exs`.
      * Tmp entries created with a `mutagen_ex_`-attributable prefix
        under `System.tmp_dir!()`.
    Allowed-write list: NONE. There is no surface the runner is
    permitted to write to as a normal side effect; a future feature
    that needs scratch space (e.g. a tmp .beam stash) must declare
    its writes here first and tag them with a `mutagen_ex_` prefix
    so the snapshot diff distinguishes them from background noise.

- id: mutagen.mutation_pipeline.r12
  priority: must
  statement: |
    A raise, throw, or exit propagating out of the loaded-mutation
    window (the span from successful `Code.compile_quoted/2` of the
    mutated AST through the per-site test run and `:code.purge/1`
    settle) MUST trigger restore before the exception re-propagates.
    The original `{kind, value, stacktrace}` MUST reach the caller
    intact — restore failure during such propagation is best-effort
    and MUST NOT mask the original cause. Equivalently, on the
    `:compile_error` branch, defensive restore failure surfaces as
    `:unrecoverable_restore_failure` (not silently discarded).

- id: mutagen.mutation_pipeline.r13
  priority: must
  statement: |
    The `:mutagen_ex` application starts a one-for-one supervisor
    (`MutagenEx.Application` → `MutagenEx.Supervisor`) whose only
    child is a named `Task.Supervisor` registered as
    `MutagenEx.TaskSup`. Every per-site mutation task spawned by
    `MutationLoop.run/1` is a child of `MutagenEx.TaskSup`. The
    supervisor is started automatically when `:mutagen_ex` boots
    (via `mod: {MutagenEx.Application, []}` in mix.exs), giving both
    `mix mutagen` CLI invocations and library callers depending on
    `:mutagen_ex` a supervision tree on application start. See
    mutagen.decision.supervision_tree.

- id: mutagen.mutation_pipeline.r14
  priority: must
  statement: |
    When `MutationLoop.run/1` escalates a timed-out site to
    `Task.Supervisor.terminate_child(MutagenEx.TaskSup, task.pid)`,
    the per-site task receives `Process.exit(_, :shutdown)`. Its
    death propagates `:shutdown` through every linked descendant.
    Descendants in two classes are reaped:
      (a) untrapped linked grandchildren (`spawn_link`'d processes,
          plain `Task.start_link`'d tasks);
      (b) trap-exit'd descendants that are themselves OTP
          supervisors or otherwise honor `:shutdown` by propagating
          it to their own children (e.g. `Phoenix.PubSub`, `Ecto`
          connection pools).
    Reaping is initiated by `terminate_child/2`'s return but
    completes asynchronously over the BEAM scheduler quantum that
    follows; the call itself is synchronous only with respect to
    the direct child task. Hand-rolled trap-exit'd descendants
    that swallow `{:EXIT, _, :shutdown}` info messages (a known
    test anti-pattern) remain leaked; snapshot-delta detection
    (mutagen.mutation_pipeline.r7) continues to detect these as
    advisory growth signals.
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

- id: mutagen.mutation_pipeline.s9
  covers: [mutagen.mutation_pipeline.r12]
  given: |
    A mutated module is loaded for a site, and a fault inside the
    loaded-mutation window (e.g. a misbehaving `:capture_io` seam,
    `MutationLoop.run/1`'s internal smuggle pattern failing, or any
    runtime error in the window) raises an exception before the runner
    can call `restore/3` itself.
  when: The exception propagates out of `MutationLoop.run/1`.
  then: |
    The runner runs restore (best-effort via `safe_restore/3`) before
    the exception escapes. After the runner returns to the caller via
    `reraise/2`, the originally-mutated module's MD5
    (`<mod>.module_info(:md5)`) matches its pre-mutation value, and
    the raised exception's `__STACKTRACE__` is preserved.

- id: mutagen.mutation_pipeline.s10
  covers: [mutagen.mutation_pipeline.r12]
  given: |
    A site whose mutated AST fails to compile (`:compile_error`
    branch). The defensive restore that follows ALSO fails (e.g. the
    AST cache became corrupted, or a test-injected `:compiler` seam
    rejects the original AST).
  when: The runner processes that site.
  then: |
    The runner aborts with `{:error, :unrecoverable_restore_failure,
    ...}` whose `message` names both the restore failure and the
    original `:compile_error` cause. The failure is NOT silently
    discarded as it was prior to bw mutagen-wrd.17.

- id: mutagen.mutation_pipeline.s11
  covers: [mutagen.mutation_pipeline.r13]
  given: |
    The `:mutagen_ex` application is started via
    `Application.ensure_all_started(:mutagen_ex)`.
  when: We inspect the BEAM's named-process registry.
  then: |
    `Process.whereis(MutagenEx.TaskSup)` returns a pid and
    `Process.whereis(MutagenEx.Supervisor)` returns a pid. Both
    pids stay alive until the application stops.

- id: mutagen.mutation_pipeline.s12
  covers: [mutagen.mutation_pipeline.r14]
  given: |
    A `Task.Supervisor.start_child(MutagenEx.TaskSup, fun)` task
    whose body `spawn_link`'s (a) a named GenServer that traps exits
    and runs a 20 ms `Process.sleep/1` in its `terminate/2` callback,
    and (b) an unnamed worker that does not trap exits.
  when: |
    The caller monitors all three pids, then calls
    `Task.Supervisor.terminate_child(MutagenEx.TaskSup, task_pid)`.
  then: |
    A `:DOWN` arrives for each monitored pid within the supervisor's
    `:shutdown_timeout` (5_000 ms upper bound). After the trapped
    GenServer's `:DOWN`, its registered name is released within a
    bounded poll window.

- id: mutagen.mutation_pipeline.s13
  covers: [mutagen.mutation_pipeline.r14, mutagen.mutation_pipeline.r7]
  given: |
    A `MutationLoop.run/1` site whose task body `spawn_link`'s a
    named GenServer (class (a)/(b) descendant per r14) and then
    blocks forever, forcing `Config.timeout_ms` to fire.
  when: The runner snapshots before and after that mutation.
  then: |
    The outcome is `{:timeout, _meta}`. The post-mutation
    snapshot delta against pre-mutation snapshot is empty for
    `Process.registered()`, `:ets.all()`, and
    `:persistent_term.info().count` — the linked descendant was
    reaped by `terminate_child/2`'s recursive shutdown.
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

- id: mutagen.mutation_pipeline.v5
  covers: [mutagen.mutation_pipeline.r12]
  kind: command
  command: mix test test/mutagen_ex/mutation_runner_raise_test.exs
  execute: true

- id: mutagen.mutation_pipeline.v6
  covers:
    - mutagen.mutation_pipeline.r13
    - mutagen.mutation_pipeline.r14
  kind: command
  command: mix test test/mutagen_ex/supervision_test.exs
  execute: true
```
