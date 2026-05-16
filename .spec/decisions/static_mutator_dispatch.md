---
id: mutagen.decision.static_mutator_dispatch
status: accepted
date: 2026-05-15
affects:
  - mutagen.mutation_enumeration
  - mutagen.mutators
---

# Static head-atom dispatch table (no mutator behaviour callback)

## Context

`mutagen-wrd.25` introduces a head-atom dispatch table so the enumerator can
cheaply pre-filter mutators per AST node: only mutators registered for the
node's head atom are asked `match?/1`. Today, the enumerator iterates every
mutator in the catalog at every AST node — call this O(nodes × mutators).
The dispatch table makes it O(nodes × applicable_mutators).

The initial architecture proposed an `@optional_callback head_atoms/0`
addition to the `MutagenEx.Mutators` behaviour. Each mutator would declare
its own head atoms, and `MutagenEx.Mutators.Dispatch` would build a table by
calling `Mutators.all/0 |> Enum.map(& &1.head_atoms())`.

The scope auditor ([04c-scope-audit.md]) flagged this as bloat:

- The `mutagen-wrd.25` ticket explicitly says "touches `mutators/*.ex` only
  if a head-atom dispatch table needs to expose it" — a static external
  table does not need to.
- The mutator catalog is closed (no external mutator authors). The list of
  head atoms is small (~10 mutators × 1–3 atoms each) and trivially captured
  in one file.
- An optional callback opens a drift surface: if a future mutator forgets
  to implement it, the dispatch falls back to `:any` — silently defeating
  the optimization for that mutator without anyone noticing.

The technical red team ([04a-technical-challenges.md, finding #5])
additionally flagged a determinism risk: any reordering of mutator
invocation order across head-matched and `:any` groups breaks byte-identity
of the JSON output. The dispatch table must preserve the canonical
`Mutators.all/0` order.

## Decision

A new module `MutagenEx.Mutators.Dispatch` carries a static, order-preserving
mapping from head atom to mutator list. No mutator behaviour change; the
mutator modules are untouched.

```elixir
defmodule MutagenEx.Mutators.Dispatch do
  @table %{
    :+ => [MutagenEx.Mutators.Arith, ...],
    :- => [MutagenEx.Mutators.Arith, ...],
    :case => [MutagenEx.Mutators.CaseDrop, ...],
    # ...
  }

  @any_mutators [MutagenEx.Mutators.Literal, MutagenEx.Mutators.ResultTuple, ...]

  def mutators_for_node(node), do: ...  # filters @any_mutators ++ @table[head] in Mutators.all/0 order
end
```

Order preservation is mechanical: `mutators_for_node/1` returns a sub-sequence
of `Mutators.all/0` (filtered, not re-ordered). This guarantees byte-identity
across runs.

The enumerator's `try_mutators/6` consumes `Dispatch.mutators_for_node/1`
instead of iterating the full catalog. An equivalence test asserts
`Mutators.all/0` (the legacy path) and `Dispatch.mutators_for_node/1`
(the new path), applied node-by-node, produce the same `match?/1` set —
locking the safety property.

## Consequences

**Positive:**
- No behaviour change in `MutagenEx.Mutators`. The mutator API contract is
  preserved exactly.
- The dispatch table is one file, one source of truth — no drift surface.
- Order-preserving by construction; determinism red-team concern closed.
- Equivalence test is straightforward (list equality on `match?/1` results).

**Negative:**
- Adding a new mutator requires two changes: the mutator module and the
  dispatch table. (Acceptable: same drift surface as the catalog itself
  in `Mutators.all/0`, which a new mutator already has to be added to.)
- The dispatch table can theoretically go stale if a mutator's `match?/1`
  starts caring about a head atom not in its table entry. The equivalence
  test catches this — but the test must run for every PR, not just `.25`.

## Related

- mutagen.mutators — the behaviour contract this avoids changing.
- mutagen.mutation_enumeration — the consumer of `Dispatch.mutators_for_node/1`.
