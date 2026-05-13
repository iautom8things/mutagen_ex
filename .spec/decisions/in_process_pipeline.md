---
id: mutagen.decision.in_process_pipeline
status: accepted
date: 2026-05-13
affects:
  - mutagen.coverage
  - mutagen.mutation_pipeline
---

# In-process pipeline with cached-AST restore

## Context

Mutation testing requires repeatedly swapping a module's bytecode, running
cited tests, observing pass/fail, and restoring the original. Two structural
shapes exist for an Elixir tool that does this:

1. **In-process**: every phase (coverage, baseline, each mutation) runs in
   the same BEAM VM as the Mix task. Swaps are done via
   `Code.compile_quoted/1`. Restore is `Code.compile_quoted/1` again on a
   cached AST.
2. **Child-BEAM per mutation**: a fresh slave node is spawned for each
   mutation, given the swapped module, runs tests, dies. Restore is trivial
   (the child dies; the parent VM is untouched).

In-process is faster (no node startup per mutation, lower latency for an LLM
verifier judge that wants quick feedback). Child-BEAM is more obviously
correct (no shared VM state means no state-drift bugs). The Muex prior art
shipped child-BEAM specifically because Elixir's `__using__/1` macros leave
attributes and registrations on the parent VM that survive a "restore".

The spike (`S2 — Spike` in the refined plan) is the explicit gate: if in-
process can be made to hold for the four documented hazardous module shapes
(`OrderSubmitter`, `OrderProcessor` with `use GenServer`, `Renderer` with
hand-rolled `__using__/1`, `Encodable` with `defimpl`), we ship in-process
for v1. If not, we pivot to child-BEAM as the fallback architecture.

## Decision

Adopt the **in-process pipeline** as the v1 default, gated on a passing
spike. The spike (S2) MUST pass for in-process to ship; a failure on any of
the 4 spike modules or the 100-iteration loop is escalated to the user, not
silently scope-restricted.

The contract for in-process is:

- Phases share a single BEAM VM. State hygiene is a per-phase responsibility
  (`:cover.stop/0` between phases, `Task.shutdown(:brutal_kill)` on
  per-mutation timeouts).
- Restore is **bytecode-identical** but not necessarily **side-effect-
  identical**. Module attributes registered via `__using__/1` macros may
  accumulate across restores. This is documented as
  `mutation.state_drift_warning` in the JSON output for any in-scope module
  whose AST contains a `use SomeModule` call, per
  [mutagen.decision.timeout_handling](timeout_handling.md) and
  [mutagen.mutation_pipeline](../specs/mutation_pipeline.spec.md) r8.
- AST is cached at startup via [mutagen.coverage](../specs/coverage.spec.md)
  r6 (`AstCache`); restore reads from the cache, never re-reads disk.

## Consequences

**Positive**:

- ~10x faster per-mutation cycle vs. child-BEAM (no node startup).
- Trivial integration: no `:slave` / `Port` machinery.
- One module map to reason about per run.

**Negative**:

- State drift on `use SomeModule` is visible in the JSON, not in the
  console. Judge prompt needs to be told about
  `mutation.state_drift_warning`.
- An infinite-loop mutation can leak named processes, ETS tables, or
  persistent terms. We mitigate by snapshotting counts and flagging
  `tainted_predecessors: true` on subsequent results (see [mutagen.decision
  .timeout_handling](timeout_handling.md)) but do not crash.
- The fallback child-BEAM architecture is a real possibility if the spike
  fails; the refined plan calls it out explicitly as an escalation path.
