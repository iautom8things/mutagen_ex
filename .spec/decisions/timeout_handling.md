---
id: mutagen.decision.timeout_handling
status: accepted
date: 2026-05-13
affects:
  - mutagen.mutation_pipeline
  - mutagen.json_schema
---

# Per-mutation timeout, brutal kill, taint flag, no hard abort

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

## Decision

- **Per-mutation timeout via `Task.async + Task.yield(timeout_ms) +
  Task.shutdown(:brutal_kill)`.** When the timeout fires, the test process
  is killed without grace.
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

**Negative**:

- Taint detection is coarse. `Process.registered()` catches named
  processes but not anonymous ones leaked via ETS-table-owner survival. v1
  accepts the coarseness; finer tracking is gold-plating per the scope
  audit.
- A truly broken mutation runner could produce hundreds of `:timeout`
  results in a row before the user notices. The user/judge is responsible
  for spotting the pattern; there is no automatic circuit breaker.
