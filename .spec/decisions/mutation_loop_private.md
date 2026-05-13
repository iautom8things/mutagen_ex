---
id: mutagen.decision.mutation_loop_private
status: accepted
date: 2026-05-13
affects:
  - mutagen.mutation_pipeline
---

# `MutationLoop` is private to `MutationRunner`, not a peer

## Context

The original architecture had an `ExUnitHarness` module that wrapped every
test run — baseline, coverage, and each mutation — with a uniform
state-hygiene contract: capture stderr, snapshot process counts, force
`max_cases: 1`, kill on timeout, capture stdout.

Two finding sets pulled in opposite directions:

- **C-T2 / H-T1 / H-T2** (technical red-team) relied on centralizing state
  hygiene. Without one home for the snapshot/kill logic, the implementations
  could drift between phases and the same bug could appear in two different
  places.
- **B2** (scope audit) called this generality the spec didn't ask for.
  Baseline and coverage don't need timeouts (if a baseline test hangs, the
  user can Ctrl-C; the tool is single-purpose). The harness was a layer of
  indirection serving only the mutation phase.

## Decision

- **Drop `ExUnitHarness` as a top-level module.**
- **Move the per-mutation logic into `MutagenEx.MutationRunner.MutationLoop`,
  a private module inside the runner.** This helper owns only:
  - per-mutation timeout wrapping (`Task.async + Task.yield +
    Task.shutdown(:brutal_kill)`)
  - stdout/stderr suppression via `ExUnit.CaptureIO`
  - pre-/post-mutation state snapshots (process/ETS/persistent_term counts)
- **Baseline and coverage call `ExUnit.run/1` directly.** They force
  `max_cases: 1` and the seed themselves; they don't need timeouts; they
  don't need stdout capture (if a baseline test hangs, that's a user-
  diagnosable problem).

`MutationLoop` is not exposed as a peer of `Baseline` / `CoverageRunner`.
Its API is internal; tests reach it through `MutationRunner`'s public
surface.

## Consequences

**Positive**:

- One module count dropped (`ExUnitHarness` → `MutationLoop` as private
  helper). Net surface area is smaller.
- The per-mutation hygiene logic still lives in one place.
- Baseline/coverage are obviously simple — no harness indirection.

**Negative**:

- Some test code for `MutationLoop` lives inside `mutation_runner_test.exs`
  rather than a dedicated test file. Acceptable: the loop's contract is
  inseparable from the runner's.
- If a future v1.x extends timeout/capture semantics to other phases, we
  either re-promote the loop to a public helper or duplicate. Document
  this as the obvious next step if it happens.
