---
id: mutagen.decision.self_mutation_refused
status: accepted
date: 2026-05-13
affects:
  - mutagen.cli
  - mutagen.mutation_pipeline
---

# Self-mutation of `MutagenEx.*` and `Mix.Tasks.Mutagen` is refused

## Context

Testability red-team's H-Tt2 finding: the recursive self-test problem. If a
user runs `mix mutagen --scope MutagenEx.MutationRunner --tests
test/mutagen_ex/mutation_runner_test.exs`, the tool would attempt to swap
its own running module's bytecode, run its own tests (which still reference
the in-flight module), classify the result, and restore. The likely
outcome: the swapped module crashes its own runner before it can finish.

A correct test of mutagen_ex against itself would require a child-BEAM
(escaping the running VM), which we explicitly aren't building for v1 per
[mutagen.decision.in_process_pipeline](in_process_pipeline.md).

## Decision

`MutationRunner.run/1` refuses to mutate any module whose name starts with
`MutagenEx.` or matches exactly `Mix.Tasks.Mutagen`. The refusal happens at
pipeline entry — before any compile, before any test run. The error JSON
carries `reason: :self_mutation_refused`.

Documented in `mix help mutagen` Known Caveats: "mutagen_ex cannot mutate
itself in v1. The tool runs in the same VM as the cited tests; mutating its
own code would corrupt the runner. Run `mutagen_ex` against itself only via
a separate harness or a child-BEAM-capable v1.x build."

## Consequences

**Positive**:

- Removes a class of broken-tool-state confusion.
- The judge prompt is told the tool can't be self-tested via the standard
  pipeline; this is a real constraint, not a leaky implementation detail.

**Negative**:

- A user who wants to verify their own mutagen_ex changes can't do it via
  `mix mutagen` directly. They'd run `mix test` (which covers the unit
  layer) and the spike integration tests (which cover the most hazardous
  pipeline behaviors).
- The check is by string prefix on module names; renaming the project
  namespace requires updating this guard in lockstep. Documented in the
  module itself.
