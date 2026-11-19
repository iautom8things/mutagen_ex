---
id: mutagen.decision.mutator_precision
status: accepted
date: 2026-11-19
affects:
  - mutagen.mutators
  - mutagen.json_schema
---

# Rate pipeline reordering and guard removal low

## Context

Manual review of survivors found two recurring sources of noise. Adjacent
pipeline stages often commute, as with LiveView assigns and updates to
different map keys. Callers often cannot supply an input that a removed
guard would have rejected. Reviewers judged 2 of 11 pipeline survivors and
4 of 8 guard removals real test gaps in the derivation set. On the
held-out set they judged 0 of 8 pipeline survivors and 1 of 4 guard
removals real gaps.

## Decision

Extend the low rating in mutagen.decision.mutator_confidence to
`pipeline` and `guard_drop`. Keep those sites in reports and count them
in the run totals. Keep the other ratings.

A single unguarded `with` else arm with an unused variable has the same
failure-value behavior as a bare wildcard. Apply that observation to the
existing `with_swap` failure-priority filter for independent clauses.

## Consequences

Consumers that gate on high-confidence survivors exclude the two operators
while retaining their results for inspection. Ratings apply to whole
operators and are provisional until more survivors have been judged.
