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
status: active
summary: Baseline + per-mutation execution with timeout, restore, classification, and taint tracking.
surface:
  - lib/mutagen_ex/selected_run.ex
  - lib/mutagen_ex/baseline.ex
  - lib/mutagen_ex/beam_cache.ex
  - lib/mutagen_ex/mutation_runner.ex
  - lib/mutagen_ex/mutation_runner/mutation_loop.ex
  - lib/mutagen_ex/progress.ex
  - lib/mutagen_ex/application.ex
  - lib/mutagen_ex/test/code_server.ex
  - lib/mutagen_ex/test/code_server_facade.ex
  - lib/mutagen_ex/test/failure_formatter.ex
  - lib/mutagen_ex/test/run_group.ex
  - lib/mutagen_ex/test/suite.ex
  - lib/mutagen_ex/test_module_discovery.ex
  - lib/mix/tasks/mutagen.ex
decisions:
  - mutagen.decision.escalation_outcomes
  - mutagen.decision.advisory_changed_code
  - mutagen.decision.changed_code_run
  - mutagen.decision.report_text_policy
  - mutagen.decision.mutation_site_paths
  - mutagen.decision.mutation_id_scheme_2
  - mutagen.decision.in_process_pipeline
  - mutagen.decision.timeout_handling
  - mutagen.decision.state_leak_snapshots
  - mutagen.decision.state_leak_name_counts
  - mutagen.decision.serial_execution_and_seed
  - mutagen.decision.per_mutant_fail_fast
  - mutagen.decision.mutation_loop_private
  - mutagen.decision.self_mutation_refused
  - mutagen.decision.supervision_tree
  - mutagen.decision.per_run_beam_cache
  - mutagen.decision.code_server_facade
  - mutagen.decision.drop_telemetry_event_api
  - mutagen.decision.parallel_experimental_gate
  - mutagen.decision.adoption_polish_efficacy
  - mutagen.decision.ancora_migration
  - mutagen.decision.host_test_setup
```

```spec-requirements
- id: mutagen.mutation_pipeline.r1
  priority: must
  statement: |
    `Baseline.run/1` executes the cited tests against unmutated code. If
    any test fails, the pipeline aborts with an error-shaped JSON whose
    `abort_reason` is `:baseline_red`. The default `baseline.failures`
    and `details.failures` list the test modules and their failure counts.
    The counts include each test ExUnit invalidates through a setup or
    teardown failure.
    With --include-host-output each entry includes the module and test
    name. No mutation runs when baseline is red.


- id: mutagen.mutation_pipeline.r2
  priority: must
  statement: |
    `Baseline.run/1` and `MutationRunner.run/1` set ExUnit options after
    the cited test files have loaded and keep them for their test runs:
    `max_cases: 1`, `seed: config.seed`, `include` and `exclude` from
    the resolved test filter, and `max_failures`. Baseline uses
    `:infinity`. The mutation phase uses `1` when `fail_fast` is true
    and `:infinity` when it is false (r20). The `formatters` list present
    after loading is kept, and Mutagen appends its failure formatter in
    baseline and in capped mutation runs. Options the phase does not set,
    such as `:timeout`, keep their loaded values. When the phase returns,
    raises, or stops at the budget, every key it set and `:trace` hold
    their post-load values again, and a key that was unset before the
    phase is unset again. Tests declared `async: true` are still run
    serially. If any cited test module was declared `async: true`, a
    warning naming that module is added to the JSON's `warnings` array.

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
    Per-mutation execution wraps `ExUnit.run/0` in a per-site task
    spawned via `Task.Supervisor.async_nolink(MutagenEx.TaskSup, ...)`
    whose deadline is `Config.timeout_ms` after the spawn. A reply the
    task completed by the deadline classifies the site per r5, and a task
    that exits without a reply before the deadline classifies `:error`.
    When the deadline passes first, the task is cancelled via the
    two-phase path documented in mutagen.decision.timeout_handling and
    mutagen.decision.supervision_tree: a `Task.shutdown(task,
    cancel_grace_ms)` window first (default 100 ms), followed by
    `Task.Supervisor.terminate_child(MutagenEx.TaskSup, task.pid)` to
    escalate and update the supervisor's child table. Both phases
    dispatch `Process.exit(_, :shutdown)`, which propagates through
    the task's link tree to descendant processes. A reply completed after
    the deadline, including one returned during the grace window, never
    classifies the site. The site is `:timeout`, except that in
    fail-fast mode (r20) a test failure recorded at or before the
    deadline makes it `:killed` with the warning `deadline exceeded
    after a test failure`. A failure recorded after the deadline does
    not count. In both cases the next site's result carries
    `tainted_predecessors: true`, and the runner calls `:code.purge/1`
    on the site's scoped modules before restore, so a killed task cannot
    leave the Code.Server holding an orphaned per-module load lock for
    the next site.

- id: mutagen.mutation_pipeline.r5
  priority: must
  statement: |
    Per-mutation classification has exactly five outcomes:
    `:killed` (a run completed by its deadline reported a failed test,
    or a fail-fast run recorded a failure by its deadline; see r4),
    `:survived` (a run completed by its deadline and all cited tests
    passed),
    `:timeout` (the deadline passed and r4 does not classify the site
    `:killed`),
    `:compile_error` (Code.compile_quoted/1 raised on the swapped AST),
    `:error` (the per-site task exited, or the test runner returned a
    value the runner cannot classify).
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
    recursion never approaches its base case. A raise, throw, or exit out
    of `ExUnit.run/0` itself is not a per-site outcome: it aborts the run
    per r21.

- id: mutagen.mutation_pipeline.r6
  priority: must
  statement: |
    After each per-mutation test run (regardless of classification), the
    original module's bytecode is restored via `:code.load_binary/3`
    against the per-run `MutagenEx.BeamCache` snapshot (a `:set, :public`
    ETS table owned by `MutationRunner.run/1`, populated by a serial
    pre-pass over `cfg.scope_records` BEFORE the per-site
    `async_stream_nolink/4` dispatch). The restore path no longer
    invokes `Code.compile_quoted/2`; the AST never participates in
    restore. On restore failure (`code_server.load_binary/3` returns
    `{:error, reason}`) the pipeline aborts with an error-shaped JSON
    `reason: :unrecoverable_restore_failure`. The snapshot pre-pass
    runs AFTER `:cover.compile_directory/1` so the cached binary IS
    the cover-instrumented binary — restore preserves coverage
    instrumentation across the per-site cycle. The ETS table is
    deleted in `run/1`'s `after` clause on every exit path
    (success, error return, raise/throw/exit). See
    [`mutagen.decision.per_run_beam_cache`](../decisions/per_run_beam_cache.md)
    and
    [`mutagen.decision.code_server_facade`](../decisions/code_server_facade.md).

- id: mutagen.mutation_pipeline.r7
  priority: must
  statement: |
    The runner compares registered process names, the count of ETS tables
    per name, and persistent term keys. Replacing a table or restarting
    a process under the same name does not count as growth. Unnamed ETS
    tables count under the name returned by `:ets.info(table, :name)`.
    Ignore the new key `:elixir_erl_compiler` and a new
    `{:logger_config, module}` key only when Logger has no explicit level
    for that module. A `state_leak` warning identifies the site and reports
    the number of changed identities and positive growth for each kind
    of state. With `--include-host-output` it lists each name or key with
    its positive count delta. It never reports persistent term values. Every subsequent
    mutation result carries `tainted_predecessors: true` until the run ends.
    In serial runs the next site reuses the previous tested site's
    after-snapshot. In parallel, each site takes both snapshots.

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
    Mutagen captures compiler and test stderr per mutant. It writes these
    diagnostics to stderr and adds them to the site's report warnings only
    with --include-host-output. The default console Logger handler bypasses
    that capture. Mutagen's recompilation suppresses its module conflict
    warning.

- id: mutagen.mutation_pipeline.r10
  priority: must
  statement: |
    The pipeline phases do not reload test modules between runs. Test
    files are loaded once via `Code.require_file/1` before the first
    `ExUnit.run/0` in the run; subsequent phases reuse the already-loaded
    bytecode. The known caveat: edits to test files mid-run are silently
    ignored. This caveat is documented in `mix help mutagen`.

    Because `ExUnit.Server` consumes its registered-module list at every
    `ExUnit.run/0` and the `use ExUnit.Case` `__after_compile__` hook
    only fires when a file is freshly evaluated, every phase that calls
    `ExUnit.run/0` after the first one MUST re-register the cited test
    modules via `ExUnit.Server.add_module/2` before its run.
    `CoverageRunner` discovers the cited cases after loading the files.
    The CLI reuses that list for baseline and mutation, keeping it only
    for the current run. Standalone baseline calls can discover cases
    after loading the files. Without this, the
    affected phase would silently classify every run as zero-test
    (`%{total: 0, failures: 0}`); for baseline that disables the
    `:baseline_red` guard rail (mutagen-wrd.37), and for coverage
    that produces empty coverage data and zero downstream enumeration
    sites whenever two `mix mutagen` invocations in the same BEAM
    cite the same test file (mutagen-wrd.38).

    Loading a test file also queues its modules in `ExUnit.Server`.
    When `Baseline.run/1` or `CoverageRunner.run/1` receives a non-empty
    `test_modules` list, it discards the queued registrations and then
    registers each cited module once, so each cited module runs once per
    phase whether that phase loaded its file or an earlier one did. An
    empty list leaves the load registrations in place. In serial mode,
    after a per-site run passes its deadline, `MutationLoop` empties the
    pending registrations once through the `ExUnitServerFacade`
    `discard_pending_modules/0` callback before the next site registers
    its modules. A runner cancelled before it consumed the registry
    therefore cannot make the next site's `add_module/2` fail.

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

    The restore path's binary swap (`:code.load_binary/3` via
    `MutagenEx.BeamCache`, per r6) is also in-memory: it mutates the
    BEAM's loaded-module table only, never writing to disk. The
    snapshot itself lives in an ETS table that dies with `run/1`.

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
    mutagen.decision.supervision_tree. The `mix mutagen` CLI preamble
    additionally boots the host project's own OTP application alongside
    this tree (see mutagen.cli.r14, mutagen.cli.r16, and
    mutagen.decision.runtime_preamble_starts_host_app); this requirement's
    contract for `MutagenEx.TaskSup` and `MutagenEx.Supervisor` is
    unaffected by that host-owned tree.

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
    test anti-pattern) survive `terminate_child/2`. The group reap
    of r22 kills such a descendant when it kept the site's group
    leader. Otherwise it remains leaked, and snapshot-delta detection
    (mutagen.mutation_pipeline.r7) continues to detect these as
    advisory growth signals.

- id: mutagen.mutation_pipeline.r15
  priority: must
  statement: |
    `MutationRunner.run/1` dispatches per-site work through
    `Task.Supervisor.async_stream_nolink/4` under
    `MutagenEx.TaskSup` when `cfg.max_concurrency > 1`; when
    `cfg.max_concurrency == 1` it stays in the caller process for
    byte-equivalent v1.0 execution. Regardless of which path runs,
    results MUST be collected in input order (the async_stream
    `:ordered: true` default) and the sequential post-fold for
    taint propagation, snapshot warnings, and per-site
    classification MUST run over the ordered outcome stream. As a
    consequence, two runs against the same `cfg.sites` with the
    same deterministic-input test stubs produce a byte-identical
    aggregate `%{results, compile_errors, state_drift_warning,
    warnings}` map across all valid `cfg.max_concurrency` values.
    The user-facing default for `--max-concurrency` is `1`
    (fully-serial, v1.0-equivalent execution) at both the Mix-task
    layer and the runner's own internal default. The caveat
    paragraph below documents why default-1 is the honest reflection
    of in-process pipeline constraints; users with collision-free
    input opt into parallelism via explicit `--max-concurrency N`
    (N > 1).

    `:on_site_completed` is the single per-site observation seam.
    The runner accepts a `:on_site_completed` callback in `cfg`
    that fires once per site as the per-site outcome becomes
    available (after sequential post-fold). The callback receives
    either `{:result, %{...}}` for completed sites (the map carries
    `id`, `file`, `line`, `column`, `mutator`, `status`, and the
    render fields) or `{:compile_error, %{...}}` for sites whose
    mutated AST refused to compile. Callback firing order matches
    input order; the runner never invokes the callback out of order
    even under `cfg.max_concurrency > 1`. The Mix task composes its
    per-site consumers around this one seam:
      - When `--stream` is set, it wires the callback to
        `MutagenEx.JsonStreamer` so each completed site emits one
        NDJSON line on the same sink the aggregate document goes to.
      - When progress is enabled (default-on-TTY; `--no-progress`
        suppresses it), it wraps the callback so each completed site
        renders one `MutagenEx.Progress` line on stderr. The Mix
        task supplies the running `index` and the `total`
        (`length(sites)`) the callback payload does not carry.

    There is no `:telemetry` event API. The producer-only
    `[:mutagen_ex, ...]` events shipped in bw mutagen-wrd.30 are
    removed and `:telemetry` is no longer a runtime dependency, so
    `mix mutagen` works from a dependency-free Mix archive (see
    [mutagen.cli.r16](cli.spec.md) and
    [mutagen.decision.drop_telemetry_event_api](../decisions/drop_telemetry_event_api.md)).

    Caveat: the in-process pipeline shares ExUnit's global server,
    the Code.Server's per-module load locks, and `:cover`
    instrumentation state across per-site tasks. Two parallel
    sites that mutate the SAME module collide on
    `Code.compile_quoted/2`; two parallel `ExUnit.run/0` calls
    interleave the global registered-modules list. The Mix task
    therefore defaults `--max-concurrency` to `1` for the
    user-facing `mix mutagen` command when the flag is not passed;
    `--max-concurrency N` (N > 1) is the explicit opt-in path for
    callers that have arranged for collision-free input. Advanced
    parallelism (per-task ExUnit servers, isolated Code.Server
    instances) is out of scope for v1.1 and tracked separately.

- id: mutagen.mutation_pipeline.r16
  priority: must
  statement: |
    The runner replaces the node at the enumerated AST path with the site's
    mutated AST. The leaf must be strictly equal to the site's original AST.
    An invalid path or a mismatched leaf produces a site-not-found warning
    without compiling a mutant. The same rule applies to bare values and
    two-tuples. All other AST nodes and metadata remain byte-identical.

- id: mutagen.mutation_pipeline.r17
  priority: must
  statement: |
    Under `cfg.max_concurrency > 1`, when the `async_stream_nolink/4`
    fold observes an `{:exit, reason}` for a per-site outer task (a
    per-site worker killed or aborted out-of-band — e.g. the
    supervisor terminated it), `MutationRunner.run/1` does NOT restore
    inside that fold branch. It halts the ordered stream with an
    outer-task-exit sentinel and runs cleanup in the post-reduce step
    via `abort_after_outer_task_exit/3`, which performs two
    strictly-ordered phases:
      1. Tear down and drain every sibling per-site `Task.Supervisor`
         child: `Task.Supervisor.terminate_child/2` each live child of
         `task_sup`, then poll until the supervisor reports no children
         (bounded retry).
      2. ONLY AFTER the drain completes, sweep ALL scoped modules
         (`cfg.scope_records`, de-duplicated by module) through
         `MutagenEx.BeamCache` restore (per r6: `:code.load_binary/3`
         against the per-run snapshot, never `Code.compile_quoted/2`).
    The ordering is the invariant: the restore sweep is never
    concurrent with a live sibling worker, because a sweep that loaded
    an original binary over a module a sibling is still testing its
    mutant on would corrupt that sibling's classification (the same
    shared-Code.Server hazard r15's caveat and r4's timeout-purge
    address, here for out-of-band worker death rather than timeout).
    A killed parallel worker therefore leaves NO module loaded as its
    mutant once `run/1` returns. The outer-task exit is itself an
    unrecoverable run condition: `run/1` aborts with an error-shaped
    JSON `reason: :unrecoverable_restore_failure` whose `message` names
    the outer-task exit; if the post-teardown restore sweep ALSO fails,
    the message additionally names the restore failure (it is not
    silently discarded). See r6 (BeamCache restore), r4 (purge-before-
    restore on timeout), r15 (parallel dispatch + shared-global-state
    caveat), and
    [`mutagen.decision.parallel_experimental_gate`](../decisions/parallel_experimental_gate.md).

    The same order holds when the budget (mutagen.cli.r13) or a site
    abort halts a parallel run. The runner terminates and drains every
    per-site task before it restores the scoped modules, and the
    mutation phase restores its ExUnit options (r2) after that. If the
    restore sweep after a budget halt fails, `run/1` aborts with
    `:unrecoverable_restore_failure`.

- id: mutagen.mutation_pipeline.r18
  priority: must
  statement: |
    When the resolved `max_concurrency` (per r15's `nil → 1` resolution)
    is greater than `1`, `MutationRunner.run/1` emits a ONE-TIME
    EXPERIMENTAL warning to `:stderr` before dispatch. The warning names
    the concrete risk — incorrect kill/survive classification and
    corrupted coverage on real ExUnit/`:cover` backends — and states
    that the safe path is the default, `--max-concurrency 1`. The
    warning is emitted at most once per `run/1` (not once per site).
    When the resolved `max_concurrency == 1`, the runner is SILENT: no
    EXPERIMENTAL warning is written to stderr.

    This is the gate half of the parallel-mode fork: the default
    remains the fully-serial, v1.0-equivalent `max_concurrency == 1`
    (r15), and `> 1` is offered as a warned, opt-in path rather than
    blocked. The user-facing documentation mirrors the gate: `mix help
    mutagen` (the `Mix.Tasks.Mutagen` `@moduledoc` / `--max-concurrency`
    option text) and the README both mark `--max-concurrency > 1`
    EXPERIMENTAL with the same risk language. The real fix for the
    shared-global-state hazard (OS-process sharding so each shard owns
    its own ExUnit server, Code.Server, and `:cover` state) is
    deliberately deferred; see
    [`mutagen.decision.parallel_experimental_gate`](../decisions/parallel_experimental_gate.md).

- id: mutagen.mutation_pipeline.r19
  priority: must
  statement: |
    The per-mutation timeout the pipeline enforces (r4's `Config.timeout_ms`)
    has a default of `30_000` ms when `--timeout-ms` is not supplied. The
    default is tuned for app-shaped (Phoenix/Ecto) projects, where a single
    mutation cycle's setup plus supplemental tests can exceed five seconds
    and would otherwise be spuriously classified `:timeout`. The
    `Mix.Tasks.Mutagen` `@moduledoc` / `--timeout-ms` option text and the
    README both state the `30_000` ms default and the app-shaped rationale.
    The value is the CLI default only — it does not change the timeout
    mechanism (r4) or any classification contract; callers still override it
    per run via `--timeout-ms`.

- id: mutagen.mutation_pipeline.r20
  priority: must
  statement: |
    `MutationRunner.run/1` takes a `fail_fast` boolean that defaults to
    `true`. With `fail_fast: true`, each per-site ExUnit run uses
    `max_failures: 1`, so ExUnit runs no further tests after the first
    failed test, and a run without a failure executes every cited test.
    With `fail_fast: false`, the cap is `:infinity` and every cited test
    runs unless the deadline (r4) interrupts it. Baseline and coverage
    always use `:infinity`. When the cited tests are deterministic and
    do not depend on each other's side effects, both modes produce the
    same ordered result IDs and statuses, except that a site whose full
    run would pass its deadline after a test had failed is `:killed` in
    fail-fast mode and `:timeout` without it. When a skipped test sets
    up or cleans up state that a later site's tests rely on, fail-fast
    can change that later site's verdict in either direction. Per
    mutagen.decision.per_mutant_fail_fast this is an accepted caveat,
    and `--no-fail-fast` (mutagen.cli.r17) runs the full suite.

- id: mutagen.mutation_pipeline.r21
  priority: must
  statement: |
    A raise, throw, or exit out of `ExUnit.run/0` is a run failure, not a
    mutation outcome. In the baseline phase `Baseline.run/1` returns
    `{:error, :ex_unit_run_failed, %{message: msg}}`. In the mutation
    phase `MutationRunner.run/1` restores the site's module, dispatches
    no further sites, and returns
    `{:error, :ex_unit_run_failed, %{message: msg, site_id: id}}` naming
    the site whose run failed. `msg` names the phase and how the run
    ended (`raised`, `caught exit`, or `caught throw`) and is available as opted-in host output per mutagen.json_schema.r19. The pipeline aborts with
    `abort_reason: "ex_unit_run_failed"`.

    The baseline pass must execute at least one test. When ExUnit's
    result has a `total` no greater than `excluded + skipped` and no
    failures, `Baseline.run/1` returns `{:error, :no_tests_run, details}`
    with `phase: :baseline`, the `excluded` and `skipped` counts, and the
    effective `include` and `exclude` filters, and the pipeline aborts
    with `abort_reason: "no_tests_run"` before any mutation runs.

- id: mutagen.mutation_pipeline.r22
  priority: must
  statement: |
    `MutationLoop.run/1` gives each site's test run its own group leader,
    a process that forwards I/O requests to the caller's group leader.
    The per-site task and every process spawned under it that keeps the
    inherited group leader, including ExUnit's monitored (unlinked) module
    and test workers, belong to that group. Pre-existing members that
    joined the group regain the leader recorded before the site.

    When the site's run ends any way other than a reply completed by its
    deadline (r4), that is on a timeout, a task exit, or an ExUnit failure
    per r21, the runner kills
    only new processes descended from the site runner, including those
    whose group leader changed, with
    `Process.exit(pid, :kill)` and waits for each
    `:DOWN`, repeating until no live descendant remains, before `run/1` returns.
    With `max_concurrency == 1` it then calls the ExUnit server's
    `discard_pending_modules/0` once (r10), so the next
    site's run sees only the modules it registers. After a reply completed
    by its deadline, members still alive get the caller's group leader
    back and keep running.

- id: mutagen.mutation_pipeline.r23
  priority: must
  statement: |
    After a timeout or runner failure the report checks the prior registered
    names and application roots. Any missing registration or changed root
    emits a warning and leaves later site verdicts tainted. The default
    report gives a count for lost names. Opted-in output includes names.

- id: mutagen.mutation_pipeline.r24
  priority: must
  statement: |
    On cancellation Mutagen reaps only new processes descended from its
    site task. Other group members regain a live previous leader or the
    pipeline leader. After a failed site, an existing name re-registered
    to a live process does not taint later verdicts. Identical report
    warnings appear once at the top level.

- id: mutagen.mutation_pipeline.r25
  priority: must
  statement: |
    Automatic case discovery for coverage, baseline and mutation selects
    loaded modules from the cited test files whose bytecode exports
    `__ex_unit__/0`. Ordinary helper modules in those files are never
    registered as cases. Cases declared in source register in compilation order within each cited
    file. A nested case registers before its enclosing case. Loaded cases without a matching
    declaration follow in module name order. If the source for a loaded
    case cannot be read or parsed, order the cases by module name.
    Registration preserves the ExUnit case's configuration, including
    parameterization and the declared `async?` value. If a cited symlink
    does not match any loaded case's compiled source path, report
    `test_file_load_failed` with the cited path and explain the mismatch.

- id: mutagen.mutation_pipeline.r26
  priority: must
  statement: |
    Stopping a site group waits for it to exit. An immediate second stop
    returns `:ok`.

- id: mutagen.mutation_pipeline.r27
  priority: must
  statement: |
    Coverage, baseline and every mutant pass the declared `async` value to
    ExUnit setup and tests. The `max_cases: 1` runner retains ExUnit's async
    and sync ordering. A timeout in an async case leaves the next site
    able to register and run the same cases in either fail-fast mode.
- id: mutagen.mutation_pipeline.r28
  priority: must
  statement: |
    A --since run with no in-scope runtime mutations finishes before host
    boot and coverage. A skipped Git path, failed source read or parse,
    or a site dropped by the runner makes the run incomplete.

- id: mutagen.mutation_pipeline.r29
  priority: must
  statement: |
    Each auto escalation pass runs only survivors and newly covered sites
    against the newly selected files. Each added file must pass an
    unmutated baseline. Red or unloadable files
    are omitted with a fixed warning. Accepted test cases register for
    later runs without reloading their modules or restarting ExUnit.Server.

- id: mutagen.mutation_pipeline.r30
  priority: must
  statement: |
    Each mutation pass uses a deadline of ten times the measured baseline
    duration with a five-second floor and the configured ceiling.
    An explicit --timeout-ms overrides the calculation. A timeout with
    fail-fast on kills a mutant only when a failure was recorded before
    its effective deadline.

- id: mutagen.mutation_pipeline.r31
  priority: must
  statement: |
    Escalation has a deadline for each admission baseline. Red,
    unloadable, crashed and timed-out candidates leave the run. If
    otherwise green files fail together, add them in ranked order while
    the combined baseline stays green. Replay accepted files' load-time environment
    changes for the selected batch. If a step cannot
    complete, retain the narrow results and warn. Explicit tests and mutation budget
    truncation disable escalation. Taint carries into later passes.

- id: mutagen.mutation_pipeline.r32
  priority: must
  statement: |
    Only survived and uncovered sites advance to another escalation step.
    A timeout keeps its status and the step that observed it. Compile errors,
    skipped sites and other terminal outcomes never run again.
- id: mutagen.mutation_pipeline.r33
  priority: must
  statement: |
    Candidate admission restores the OS environment and the environment of
    every loaded application after each probe. The admitted files' load-time
    environment changes apply only to their own pass. Side effects outside
    those environments may persist after a candidate runs and is dropped.
- id: mutagen.mutation_pipeline.r34
  priority: must
  statement: |
    Death of the test group leader kills the current mutant and permits the
    next site to run. In a baseline it is a red outcome. In candidate
    admission that outcome drops the file and permits escalation to continue.
- id: mutagen.mutation_pipeline.r35
  priority: must
  statement: |
    A single candidate baseline gets ten times the narrow baseline duration
    with a thirty-second floor, capped by the configured host boot and
    mutant timeout ceilings. A combined baseline gets the single-candidate
    deadline per file, capped by the host boot timeout.

```

```spec-scenarios
- id: mutagen.mutation_pipeline.s1
  covers: [mutagen.mutation_pipeline.r1]
  given:
    - A cited test suite has one failing test before any mutation.
  when:
    - "`Baseline.run/1` executes."
  then:
    - The pipeline halts.
    - "The JSON has `aborted: true`, `abort_reason: \"baseline_red\"`, and `baseline.failures` contains the failing module and its failure count."
    - No mutation phase runs.

- id: mutagen.mutation_pipeline.s2
  covers: [mutagen.mutation_pipeline.r3]
  given:
    - A scope target `--scope MutagenEx.MutationRunner` resolves to one of the tool's own modules.
  when:
    - "`MutationRunner.run/1` starts."
  then:
    - Run aborts before any compile.
    - "JSON `aborted: true`, `abort_reason: \"self_mutation_refused\"`."

- id: mutagen.mutation_pipeline.s3
  covers: [mutagen.mutation_pipeline.r4, mutagen.mutation_pipeline.r5]
  given:
    - A mutation creates a deterministic infinite loop in the mutated module (e.g., `:arith` flipping `count_down(n - 1)` to `count_down(n + 1)` so the recursion diverges from its base case).
    - "`Config.timeout_ms` is 1000."
  when:
    - The mutation phase processes that site.
  then:
    - Approximately 1000ms after the test run begins, the site is classified `:timeout`.
    - "The next-iteration mutation result has `tainted_predecessors: true`."
    - The runner continues to subsequent sites rather than aborting.
    - "Note: a `:case_drop` mutation that drops a recursion's base case does NOT produce `:timeout` in this scenario — it raises `CaseClauseError` on the first iteration that reaches the dropped value and classifies `:killed` (per r5 and mutagen.mutators.r8)."

- id: mutagen.mutation_pipeline.s4
  covers: [mutagen.mutation_pipeline.r5]
  given:
    - "A mutated module produces source that `Code.compile_quoted/1` refuses (rare: the mutator's `validate/1` should have caught it, but we accept discoveries at runtime)."
  when:
    - The mutation phase processes that site.
  then:
    - "The site is classified `:compile_error`."
    - "The `mutation.compile_errors[]` array gets an entry."
    - The kill rate denominator does NOT increase by this site.

- id: mutagen.mutation_pipeline.s5
  covers: [mutagen.mutation_pipeline.r6]
  given:
    - A successful mutation phase completes for a given site.
  when:
    - The next site begins processing.
  then:
    - "`:code.which(<the just-mutated module>)` returns the same path it returned before the mutation."
    - "The module's MD5 (via `<mod>.module_info(:md5)`) matches the original module's MD5 from before mutation."

- id: mutagen.mutation_pipeline.s6
  covers: [mutagen.mutation_pipeline.r7]
  given:
    - A mutation timeout leaves a named GenServer (or new ETS table) registered.
  when:
    - The runner snapshots after that mutation.
  then:
    - The warning gives the count and positive delta. Opted-in output also gives the registered process or ETS name.
    - "Every mutation result subsequent to this one in `mutation.results[]` has `tainted_predecessors: true`."

- id: mutagen.mutation_pipeline.s7
  covers: [mutagen.mutation_pipeline.r8]
  given:
    - A scoped module's source contains `use GenServer`.
  when:
    - That module is selected as a mutation target.
  then:
    - "The JSON has `mutation.state_drift_warning` mentioning `[GenServer]` in the relevant module's record."
    - The pipeline continues; the warning is non-fatal.

- id: mutagen.mutation_pipeline.s8
  covers: [mutagen.mutation_pipeline.r9]
  given:
    - A mutated module produces compiler warnings on stderr.
  when:
    - The mutation runs.
  then:
    - "The warnings appear in `mutation.results[i].warnings` of that site."
    - No stderr line was written to the actual terminal.

- id: mutagen.mutation_pipeline.s9
  covers: [mutagen.mutation_pipeline.r12]
  given:
    - A mutated module is loaded for a site, and a fault inside the loaded-mutation window (e.g. a misbehaving `:capture_io` seam, or any runtime error in the window) raises an exception before the runner can call `restore/3` itself.
  when:
    - The exception propagates out of `MutationLoop.run/1`.
  then:
    - The runner runs restore (best-effort via `safe_restore/3`) before the exception escapes.
    - "After the runner returns to the caller via `reraise/2`, the originally-mutated module's MD5 (`<mod>.module_info(:md5)`) matches its pre-mutation value, and the raised exception's `__STACKTRACE__` is preserved."

- id: mutagen.mutation_pipeline.s10
  covers: [mutagen.mutation_pipeline.r12]
  given:
    - A site whose mutated AST fails to compile (`:compile_error` branch). The defensive restore that follows ALSO fails (e.g. the AST cache became corrupted, or a test-injected `:compiler` seam rejects the original AST).
  when:
    - The runner processes that site.
  then:
    - "The runner aborts with `{:error, :unrecoverable_restore_failure, ...}` whose `message` names both the restore failure and the original `:compile_error` cause."
    - The failure is NOT silently discarded as it was prior to bw mutagen-wrd.17.

- id: mutagen.mutation_pipeline.s11
  covers: [mutagen.mutation_pipeline.r13]
  given:
    - "The `:mutagen_ex` application is started via `Application.ensure_all_started(:mutagen_ex)`."
  when:
    - We inspect the BEAM's named-process registry.
  then:
    - "`Process.whereis(MutagenEx.TaskSup)` returns a pid and `Process.whereis(MutagenEx.Supervisor)` returns a pid."
    - Both pids stay alive until the application stops.

- id: mutagen.mutation_pipeline.s12
  covers: [mutagen.mutation_pipeline.r14]
  given:
    - "A `Task.Supervisor.start_child(MutagenEx.TaskSup, fun)` task whose body `spawn_link`'s (a) a named GenServer that traps exits and runs a 20 ms `Process.sleep/1` in its `terminate/2` callback, and (b) an unnamed worker that does not trap exits."
  when:
    - The caller monitors all three pids, then calls `Task.Supervisor.terminate_child(MutagenEx.TaskSup, task_pid)`.
  then:
    - "A `:DOWN` arrives for each monitored pid within the supervisor's `:shutdown_timeout` (5_000 ms upper bound)."
    - "After the trapped GenServer's `:DOWN`, its registered name is released within a bounded poll window."

- id: mutagen.mutation_pipeline.s13
  covers: [mutagen.mutation_pipeline.r14, mutagen.mutation_pipeline.r7]
  given:
    - A `MutationLoop.run/1` site whose task body `spawn_link`'s a named GenServer (class (a)/(b) descendant per r14) and then blocks forever, forcing `Config.timeout_ms` to fire.
  when:
    - The runner snapshots before and after that mutation.
  then:
    - "The outcome is `{:timeout, _meta}`."
    - "The post-mutation snapshot delta against pre-mutation snapshot is empty for `Process.registered()`, `:ets.all()`, and the persistent term keys. The linked descendant was reaped by `terminate_child/2`'s recursive shutdown."

- id: mutagen.mutation_pipeline.s14
  covers: [mutagen.mutation_pipeline.r16]
  given:
    - Two equal bare literals under the same parent on one source line.
  when:
    - The runner swaps the second site.
  then:
    - The first literal is unchanged and the second is replaced.

- id: mutagen.mutation_pipeline.s15
  covers: [mutagen.mutation_pipeline.r16]
  given:
    - A path whose leaf differs from the original AST recorded on the site.
  when:
    - The runner attempts to apply the mutation.
  then:
    - It emits a site-not-found warning and skips compilation.

- id: mutagen.mutation_pipeline.s16
  covers: [mutagen.mutation_pipeline.r6]
  given:
    - A site whose scoped module exists on the BEAM's code path (has a real `.beam` resolvable via `:code.where_is_file/1`). The `MutationRunner.run/1` cycle compiles the mutated AST, runs the test, and reaches the restore point.
  when:
    - "The runner invokes `MutagenEx.BeamCache.restore/3` for that module via the configured `code_server` seam."
  then:
    - "The `code_server.load_binary/3` callback is invoked exactly once with the original `{module, filename, binary}` triple captured by the pre-pass `snapshot/3` (no `Code.compile_quoted/2` call is made on the original AST during restore)."
    - "After the cycle, the module's MD5 (via `<mod>.module_info(:md5)`) matches the pre-mutation MD5."
    - "The ETS table holding the snapshot is deleted when `run/1` returns (`:ets.info/1` returns `:undefined`); on a `raise`/`throw`/`exit` exit path the `after` clause still deletes the table."

- id: mutagen.mutation_pipeline.s17
  covers: [mutagen.mutation_pipeline.r6]
  given:
    - A mutation cycle where the BeamCache snapshot pre-pass has run and populated the ETS table for every scoped module BEFORE the per-site loop dispatches.
  when:
    - The `async_stream_nolink/4` dispatch begins and two workers handle sites that target the SAME module (e.g. duplicate-position sites or two sites in different functions of the same module).
  then:
    - "Neither worker triggers a snapshot during its task body — both read from the pre-populated table. `code_server.get_object_code/1` is invoked once per distinct scoped module during the pre-pass and zero times during the per-site loop."
    - "The TOCTOU window between \"current module load state\" and \"snapshot capture\" is therefore closed at the run boundary: even under `--max-concurrency > 1`, no two workers can race to snapshot the same module."

- id: mutagen.mutation_pipeline.s18
  covers: [mutagen.mutation_pipeline.r17]
  given:
    - "`cfg.max_concurrency` is 2, with two sites against the same scoped (snapshotted) module: a `crash` site whose mutated-AST compile causes its per-site outer task to exit, and a `blocking` site whose worker has started and is still live when the crash exit is observed."
    - The snapshot ETS table holds the original `{module, filename, binary}` for that module (captured by the pre-pass).
  when:
    - "`MutationRunner.run/1` executes and the ordered `async_stream_nolink/4` fold observes the crash site's `{:exit, reason}`."
  then:
    - "`run/1` returns `{:error, :unrecoverable_restore_failure, %{message: msg}}` where `msg` contains `\"per-site outer task exited\"`."
    - "The restore sweep invokes the `code_server` `load_binary/3` callback exactly once for that module with the snapshot's original `{module, filename, binary}` triple — and at the moment that call is recorded, the task supervisor has NO live children (the sibling `blocking` worker was already torn down and drained). The recorded `live_children` for the restore call is `[]`."
    - The `blocking` worker is observed to have started before the teardown (the sweep tore down a genuinely live sibling, not a never-started one).

- id: mutagen.mutation_pipeline.s19
  covers: [mutagen.mutation_pipeline.r18]
  given:
    - A deterministic test backend that classifies every site as a passing run.
  when:
    - "`MutationRunner.run/1` runs once with `max_concurrency: 3` (stderr captured), and once with `max_concurrency: 1` (stderr captured)."
  then:
    - "Under `max_concurrency: 3`, stderr contains the EXPERIMENTAL warning exactly once: it names `--max-concurrency > 1 is EXPERIMENTAL`, `incorrect kill/survive classification`, `corrupted coverage`, and the safe-path phrase `default, --max-concurrency 1`. A single-line count of the warning marker is `1` (one-time, not per-site across the 3 sites)."
    - "Under `max_concurrency: 1`, captured stderr is empty (`\"\"`): no EXPERIMENTAL warning is emitted."

- id: mutagen.mutation_pipeline.s20
  covers: [mutagen.mutation_pipeline.r20]
  given:
    - A fixture with four sites and three cited tests in two modules. The first three mutants each fail both tests of the first module. The fourth mutant fails no test.
  when:
    - The pipeline runs once with `--no-fail-fast` and once in the default mode.
  then:
    - "Both runs report the same ordered `{id, status}` list: three `killed` results followed by one `survived` result."
    - In the default mode each killed run executes only the first test, with `max_failures` set to 1, and the surviving run executes all three tests.
    - With `--no-fail-fast` every run executes all three tests with `max_failures` set to `:infinity`.

- id: mutagen.mutation_pipeline.s21
  covers: [mutagen.mutation_pipeline.r4]
  given:
    - A per-site deadline of 250 ms.
    - In one fixture the first test fails and a later test sleeps 800 ms. In another the first test sleeps 800 ms before it fails. In a third the tests finish in time with a failure and an after-suite callback then sleeps 800 ms.
    - A fake runner that returns a clean result, or records a failure, only after it receives the cancellation `:shutdown`.
  when:
    - Each site reaches its deadline.
  then:
    - In the first and third fixtures the failure recorded before the deadline gives `killed` in the default mode and `timeout` with `--no-fail-fast`. The kill carries the warning `deadline exceeded after a test failure`.
    - The site whose first failure comes after the deadline is `timeout` in both modes.
    - A clean reply or a failure produced during cancellation leaves the site `timeout`.
    - "In every case the next result has `tainted_predecessors: true` and the scoped modules were purged."

- id: mutagen.mutation_pipeline.s22
  covers: [mutagen.mutation_pipeline.r2, mutagen.mutation_pipeline.r10]
  given:
    - "A cited test file that calls `ExUnit.configure/1` while it loads, setting `max_failures: 1`, `seed: 9`, `max_cases: 8`, a formatter list, include and exclude filters, and `timeout: 9_999`. Its module has two failing tests."
  when:
    - "`Baseline.run/1` loads the file cold, and later `CoverageRunner.run/1` loads it again after it was unrequired."
  then:
    - "Both tests run once in each phase with `max_failures: :infinity`, `seed: 0`, `max_cases: 1`, the resolved include and exclude, `timeout: 9_999`, and the host formatter list. Baseline adds Mutagen's failure formatter and coverage does not."
    - Baseline reports two failures.
    - After each phase the ExUnit environment holds the values the file set.

- id: mutagen.mutation_pipeline.s23
  covers: [mutagen.mutation_pipeline.r10]
  given:
    - A host formatter whose start blocks for 500 ms during the first mutant's run, with a per-site deadline of 150 ms and three sites.
  when:
    - The serial mutation phase runs in either fail-fast mode.
  then:
    - "The results are `timeout`, `killed`, `killed`, and the second result has `tainted_predecessors: true`."
    - A bare `ExUnit.run/0` afterwards reports zero tests.

- id: mutagen.mutation_pipeline.s24
  covers: [mutagen.mutation_pipeline.r20]
  given:
    - A suite whose last module cleans up state that an earlier test sets, or restores state that an earlier test relaxes.
  when:
    - The pipeline runs with `--no-fail-fast` and in the default mode.
  then:
    - With the cleanup module, two sites that survive with `--no-fail-fast` are `killed` in the default mode, and the leftover state is still set afterwards.
    - With the restore module, a site that `--no-fail-fast` kills survives in the default mode.
    - Both runs report the same site IDs in the same order.

- id: mutagen.mutation_pipeline.s25a
  covers: [mutagen.mutation_pipeline.r21, mutagen.mutation_pipeline.r5]
  given:
    - "The test runner raises a `RuntimeError` from `ExUnit.run/0` while site `e1` is loaded."
  when:
    - "`MutationRunner.run/1` processes `e1`."
  then:
    - "It returns `{:error, :ex_unit_run_failed, %{site_id: \"e1\", message: msg}}`, where `msg` contains `ExUnit.run/0 raised during mutation`."
    - "No result for `e1` is classified `:error`."

- id: mutagen.mutation_pipeline.s25b
  covers: [mutagen.mutation_pipeline.r21]
  given:
    - "The cited selection's filters exclude one test and skip the other, so the baseline pass reports `%{total: 2, excluded: 1, skipped: 1, failures: 0}`."
  when:
    - "`Baseline.run/1` runs."
  then:
    - "It returns `{:error, :no_tests_run, %{phase: :baseline, excluded: 1, skipped: 1, ...}}` and no mutation runs."

- id: mutagen.mutation_pipeline.s26
  covers: [mutagen.mutation_pipeline.r22]
  given:
    - A site's test run spawns an unlinked worker and then blocks past `Config.timeout_ms`.
  when:
    - "`MutationLoop.run/1` returns `{:timeout, _}`."
  then:
    - The worker is no longer alive when `run/1` returns.
    - In a run that completes normally, a worker that is still alive afterwards has the caller's group leader.
```

```spec-verification
- kind: tagged_tests
  target: test/mutagen_ex
  covers:
    - mutagen.mutation_pipeline.r1
    - mutagen.mutation_pipeline.r2
    - mutagen.mutation_pipeline.r3
    - mutagen.mutation_pipeline.r4
    - mutagen.mutation_pipeline.r5
    - mutagen.mutation_pipeline.r6
    - mutagen.mutation_pipeline.r7
    - mutagen.mutation_pipeline.r8
    - mutagen.mutation_pipeline.r9
    - mutagen.mutation_pipeline.r10
    - mutagen.mutation_pipeline.r11
    - mutagen.mutation_pipeline.r12
    - mutagen.mutation_pipeline.r13
    - mutagen.mutation_pipeline.r14
    - mutagen.mutation_pipeline.r15
    - mutagen.mutation_pipeline.r16
    - mutagen.mutation_pipeline.r17
    - mutagen.mutation_pipeline.r18
    - mutagen.mutation_pipeline.r19
    - mutagen.mutation_pipeline.r20
    - mutagen.mutation_pipeline.r21
    - mutagen.mutation_pipeline.r22
    - mutagen.mutation_pipeline.r23
    - mutagen.mutation_pipeline.r24
    - mutagen.mutation_pipeline.r25
    - mutagen.mutation_pipeline.r26
    - mutagen.mutation_pipeline.r27
    - mutagen.mutation_pipeline.r32
    - mutagen.mutation_pipeline.r34
    - mutagen.mutation_pipeline.r35
- kind: tagged_tests
  target: test/integration/gate_wiring_test.exs
  covers:
    - mutagen.mutation_pipeline.r32
    - mutagen.mutation_pipeline.r33
    - mutagen.mutation_pipeline.r34
    - mutagen.mutation_pipeline.r35
```
