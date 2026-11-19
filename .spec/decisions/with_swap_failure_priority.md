---
id: mutagen.decision.with_swap_failure_priority
status: accepted
date: 2026-11-19
affects:
  - mutagen.mutators
---

# Keep only with swaps that can change which failure wins

## Context

`with_swap` reorders two leading `<-` clauses. The swap only matters when
both clauses can fail and the two failures are observable as different
values, or when moving a binding forward changes what another clause reads.
Many retained swaps could do neither. A clause that always matches, two
clauses that fail with the same value, or a single `_ ->` `else` arm all
produce survivors that no test can kill. An earlier filter also discarded
swaps whose clauses depended on each other, and a review showed tests that
killed those swaps on the base revision.

mutagen.decision.validate_predicates names three skip reasons. This
decision adds three more without changing that decision's mechanism:
`validate/1` still runs on the swapped node before any compile.

## Decision

Swap only the first two leading arrows. Later clauses and the `do` and
`else` blocks keep their positions.

Validate syntactically, without scope analysis:

1. Keep the existing `:bound_var_used_before_binding` check. A
   variable-shaped name in the moved-first right-hand side that the
   moved-second pattern binds skips the swap. Module attributes and
   binary modifiers are not reads.
2. Treat the clauses as dependent, and keep the swap, when a name bound
   by either pattern appears anywhere in the other clause or either
   clause uses `binding`, no-argument `dbg` or `__ENV__`.
3. Only for independent clauses, skip with
   `:insufficient_refutable_patterns` when either clause always matches,
   `:indistinguishable_failures` when both right-hand sides are the same
   variable or equal literals, and `:else_ignores_failure` when `else` is
   a single `_` arm.

Leave missing bindings in pins, guards and binary sizes to the compiler.
A kept swap that reads a binding no longer in scope becomes a
`compile_errors` entry, not a skip.

Compare literals with their own normalization that drops position
metadata and orders scalar-keyed maps. Leave the shared ID normalization
and hash alone, so site IDs do not change.

## Consequences

The checks read unexpanded source. A name under a nested `fn`, `case`,
`for`, `receive`, `rescue`, `with`, `match?`, match, `destructure` or
`quote` still counts as a read, so step 1 can skip a valid swap. A name an
outer binding supplies is also skipped. Macros can hide reads, bindings
and effects.

The noise filters can discard a swap that only changes side effects or
which exception is raised, and a kept swap can still be equivalent.
mutagen.decision.mutator_confidence rates `with_swap` low for that
reason.

A kept pin, guard or size swap without an outer binding costs one compile
and appears in `compile_errors`.
