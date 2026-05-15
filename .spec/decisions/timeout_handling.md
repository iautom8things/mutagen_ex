---
id: mutagen.decision.timeout_handling
status: accepted
date: 2026-05-13
affects:
  - mutagen.mutation_pipeline
  - mutagen.json_schema
---

# Per-mutation timeout, cooperative cancel + code-server settle, taint flag, no hard abort

## Context

Three red-team findings converged on this decision:

- **C-T4 — Hard-abort emits no partial JSON.** The original architecture
  specified a "3 consecutive timeouts → hard abort" branch that exited the
  Mix task without emitting a `mutation` block. The judge would be left with
  nothing to evaluate.
- **H-T2 — Timeout leaks ETS / named GenServers / persistent_term.** When
  the runner kills a hung test with `Task.shutdown(:brutal_kill)`, any
  process the test linked, any ETS table it created, and any `persistent_term`
  it set are still around. The next mutation runs against a contaminated VM.
- **B3 — Drop "3 consecutive timeouts → hard abort".** The scope audit
  argued the abort threshold was speculative — there's no evidence 3 is the
  right number, and it adds a state-machine branch that increases complexity.

The tension: C-T4 demanded a universal partial-report schema; B3 argued
against an abort threshold. H-T2 demanded *some* response to taint without
the complexity of perfect cleanup.

### Amendment (bw mutagen-wrd.13)

A fourth concern surfaced during S7 end-to-end driver authoring:

- **MUT-13 — `Task.shutdown(:brutal_kill)` corrupts Code.Server load
  locks.** A timed-out task that is mid-flight inside `:code.load_binary/3`
  (during the cover-recompile cycle) gets brutal-killed before the
  code_server can complete the load transaction it was driving. The
  per-module load lock can remain "held" in the code_server's tracking
  state, and the next site's compile-and-load cycle deadlocks waiting on
  it. Empirically this blocked Scenario 4 (`infinite_looper.ex` →
  `:timeout`) and Scenario 7 (`EctoUser` bytecode-identical restore) from
  sharing a BEAM with the other e2e scenarios in mutagen-wrd.9.

The fix is two-phase cancellation plus a `:code.purge/1` settle pass,
described below. The original "kill without grace" wording in r4 was
narrowed to "killed via the two-phase path" — classification semantics
are unchanged.

## Decision

- **Per-mutation timeout via `Task.async + Task.yield(timeout_ms)` +
  two-phase cancellation.** The happy path is `Task.yield`. When the
  timeout fires, the loop cancels cooperatively first:
    1. `Task.shutdown(task, cancel_grace_ms)` — issues a trappable
       `:shutdown` signal. A task that traps exits at a hot-loop
       checkpoint OR sits in a normal `receive` unwinds cleanly during
       the grace window. Default grace is 100ms — small enough to keep
       per-site latency in the same envelope as the brutal-only path;
       large enough that the code_server's own DOWN handling can complete
       any in-flight `code:load_binary/3` transaction the task was
       blocking on.
    2. `Task.shutdown(task, :brutal_kill)` — last-resort escape for tasks
       genuinely stuck in BIF code with no checkpoint reachable. Note
       that `Task.shutdown/2` with an integer grace ALSO internally
       escalates to `Process.exit(pid, :kill)` after the grace expires
       when the task is trapping exits and ignored `:shutdown`; in that
       case the explicit second call is a no-op but kept for shape
       symmetry.
- **Classification stays `:timeout` regardless of which phase cleared
  the task.** r4 cares about the wall-clock budget, not the unwind
  mechanism. The cancel-mode taxonomy (`:graceful` / `:brutal` /
  `:n_a`) is internal telemetry — surfaced in `MutationLoop`'s outcome
  meta for tests, not in the JSON.
- **Post-`:timeout` `:code.purge/1` settle on the site's scoped
  modules.** After a `:timeout` outcome, before restore, the runner
  calls `:code.purge/1` on every module in `scope_records` that
  belongs to the just-mutated file. `:code.purge/1` removes the old
  code revision for a module; in current OTP it also clears the
  code_server's tracking state for that module, releasing any orphaned
  per-module load lock left by a brutal-killed task mid-`code:load_binary/3`.
  Modules with no old revision are a no-op. The purge runs only on
  `:timeout` outcomes to keep the happy path cheap — non-timeout sites
  do NOT purge.
- **No "3-consecutive-timeouts" hard abort.** Each timeout is classified
  `:timeout` in `mutation.results`; the runner continues to the next site.
  The judge can see "10 timeouts in a row" and decide what to do with the
  result.
- **Taint detection via process/ETS/persistent_term snapshots.** Before
  each mutation, snapshot `length(Process.registered())`, `length(:ets.all
  ())`, and `:persistent_term.info().count`. After each mutation, compare.
  If any grew, emit a warning naming the new entity AND flag every
  subsequent mutation result with `tainted_predecessors: true`.
- **Universal partial-report schema for genuinely unrecoverable exits.**
  Any path that exits without completing the pipeline emits the same JSON
  schema with `aborted: true`. The set of unrecoverable exits is small: red
  baseline, unrecoverable restore failure, cover-already-running. Timeout
  is NOT in this set.

## Consequences

**Positive**:

- The judge always sees a complete `mutation.results` array (modulo
  unrecoverable exits), even when many mutations time out.
- State drift is visible: `tainted_predecessors: true` lets the judge
  discount results that came after a leak.
- The state machine is simpler: one fewer counter, one fewer abort
  condition.
- The Code.Server stays healthy across `:timeout` events: the per-site
  cycle no longer poisons the BEAM by orphaning per-module load locks.
  This is what unblocks the S7 end-to-end driver Scenario 4
  (`infinite_looper.ex` → `:timeout`) from running in the same BEAM as
  the other scenarios. (Scenario 7 — `EctoUser` bytecode-identical
  restore — was originally bundled into this rationale under a
  "cover-instrumentation issue with Ecto-style DSLs" framing. The
  mutagen-wrd.19 spike disproved that framing: every macro-injected
  callback on `LaneFixture.EctoUser` survives the
  `:cover.compile_beam/1` → `:cover.stop/0` → `:code.purge/1` →
  `:code.load_file/1` cycle byte-for-byte, and the baseline-red was a
  fixture-test assertion bug — `Keyword.get_values/2` over a
  `persist: true` attribute returns a list-of-lists. Scenario 7 is
  unblocked by mutagen-wrd.32's assertion fix, NOT by this decision's
  load-lock release. The two-phase cancel + `:code.purge/1` settle is
  still correct for Scenario 4 and for any future timeout-classified
  site whose task is mid-flight in `:code.load_binary/3`.)

**Negative**:

- Taint detection is coarse. `Process.registered()` catches named
  processes but not anonymous ones leaked via ETS-table-owner survival. v1
  accepts the coarseness; finer tracking is gold-plating per the scope
  audit.
- A truly broken mutation runner could produce hundreds of `:timeout`
  results in a row before the user notices. The user/judge is responsible
  for spotting the pattern; there is no automatic circuit breaker.
- The graceful-cancel phase adds up to `cancel_grace_ms` (default 100ms)
  per actually-timing-out site. Sites that don't time out pay zero
  extra cost; sites that time out via the brutal path pay the full
  grace window before brutal_kill clears them. For typical runs where
  timeouts are the exception, the added wall-clock is negligible.
- `:code.purge/1`'s public contract names the old-revision removal; the
  load-lock-release behaviour is an implementation detail of the current
  OTP code_server. If a future OTP changes that, the post-timeout settle
  path may need to be revisited (e.g. with `code:delete/1` + reload, or
  with a peer-node sandbox per the bw mutagen-wrd.13 alternative
  resolution path 2).
