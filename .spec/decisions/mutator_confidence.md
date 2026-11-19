---
id: mutagen.decision.mutator_confidence
status: accepted
date: 2026-11-19
affects:
  - mutagen.mutators
  - mutagen.json_schema
---

# Rate each mutator's survivors as high or low confidence

## Context

A CI gate that fails on every survivor also fails on equivalent mutants.
Some operators produce far more of them than others. `with_swap` keeps
pairs whose failures can be identical at runtime or can never occur
together, even after mutagen.decision.with_swap_failure_priority filters
the obvious cases. Consumers need a stable field to separate those
survivors from the rest without parsing mutator names.

## Decision

Give every catalog mutator a static rating, `:high` or `:low`. The
rating is a qualitative judgment about the operator, not a measurement of
any single site. `with_swap` is `:low`. The other nine are `:high`.

Add an optional `confidence/0` callback to the mutator behaviour. A
registered module that omits it rates `:high`.
`MutagenEx.Mutators.confidence/1` resolves a name through the closed
catalog of mutagen.mutators.r7 and raises `ArgumentError` for a name
outside it, so an unregistered name cannot silently rate `:high`.

Emit the rating as `confidence` on every `mutation.results[]` entry and
every NDJSON `result` line, for any status. Adding a field does not
change report schema version `"2"`. Compile errors, skipped entries and
envelopes keep their shape. Both ratings count toward the summary
counters and the kill rate.

## Consequences

A gate can select `status == "survived" and confidence == "high"`. A
high-rated survivor can still be equivalent, and the ratings carry no
measured equivalence rate. Publish observed equivalent-survivor counts
with their denominators before recommending a hard threshold.

Readers that compare raw bytes or exact key sets of results must accept
the added field. A new mutator must state its rating or accept `:high`.
