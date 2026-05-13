---
id: mutagen.decision.validate_predicates
status: accepted
date: 2026-05-13
affects:
  - mutagen.mutators
  - mutagen.mutation_enumeration
  - mutagen.json_schema
---

# Every mutator carries a `validate/1` predicate

## Context

Red-team's C-T2 finding: "Mutator catalog produces no-ops + uncompilables."
Two failure modes contaminate the kill rate:

- **No-op mutations**: a swap produces source that means the same thing as
  the original (e.g., swapping `+` and `+` is impossible by construction,
  but swapping `case` clauses where the remaining clauses still cover all
  inputs *is* effectively a no-op). The test passes; the runner counts a
  "survived" mutation; the judge sees the test suite has a gap that's
  actually impossible to plug.
- **Uncompilable mutations**: a swap produces source that
  `Code.compile_quoted/1` refuses. Without distinction, this either crashes
  the runner or silently inflates the survived count.

Initial classification (`:killed` / `:survived` / `:timeout` / `:error`) was
insufficient to express these cases honestly.

## Decision

Every mutator implements three callbacks:

- `match?(ast_node) :: boolean` — does this node qualify for mutation?
- `mutate(ast_node) :: ast_node` — perform the swap.
- `validate(swapped_ast_node) :: :ok | {:skip, atom}` — is the swap
  sensible? Possible skip reasons in v1: `:structurally_invalid`,
  `:no_op_shadowed`, `:bound_var_used_before_binding`.

`validate/1` runs **after** the AST swap and **before** any compile. Sites
with `{:skip, reason}` are excluded from `mutation.total` entirely. They
appear in a parallel `mutation.skipped[]` JSON array carrying `{site_id,
reason}`.

Runtime classification now has FIVE outcomes (not four):
`:killed`, `:survived`, `:timeout`, `:compile_error`, `:error`.
`:compile_error` outcomes are NOT counted in the kill-rate denominator:

```
kill_rate = killed / (total - compile_error_count)
```

`:compile_error` lives in a parallel `mutation.compile_errors[]` array for
visibility but doesn't pollute the rate.

## Consequences

**Positive**:

- The judge sees an honest kill rate. Equivalent mutants (the
  `:no_op_shadowed` case) are filtered before they confuse the metric.
- Skipped sites are still visible — the judge can see "300 sites
  enumerated, 50 skipped because the catalog has no sensible swap for
  them" rather than silently dropped.
- Validators are per-mutator, so adding a new mutator requires explicitly
  saying what counts as a sensible swap for it.

**Negative**:

- More code per mutator (~50 LOC adds ~20 LOC for `validate/1`).
- `validate/1` is best-effort, not perfect. Some equivalent mutants will
  still slip through to runtime and classify as `:survived`. The judge
  prompt must accept that "survived" doesn't strictly mean "test suite
  gap" — it means "the catalog couldn't tell the difference".
- The five-outcome classification + parallel arrays add JSON surface area
  (see [mutagen.json_schema](../specs/json_schema.spec.md) r3).
