---
id: mutagen.decision.adoption_polish_efficacy
status: accepted
date: 2026-06-25
affects:
  - mutagen.ast
  - mutagen.mutation_enumeration
  - mutagen.scope_resolution
  - mutagen.mutation_pipeline
  - mutagen.cli
---

# Adoption-polish efficacy findings: nested-module qualification + app-shaped timeout default

## Context

The `mutagen-3fa` epic ("Phoenix/Ecto adoption polish — efficacy-study
findings") landed three behavior changes through child tickets that
carried no `Advances:` field, so no subject spec or decision was updated
when they merged. Once the epic branch was rebased onto the current
`main` (which had since adopted SpecLedEx tooling and a much larger
current-truth corpus), `mix spec.check`'s branch guard correctly flagged
the accumulated diff as a cross-cutting change spanning multiple subjects
with no decision file. This decision closes that gap and records the
posture the shipped code already implements. The changes:

- **Nested-module qualification** (`mutagen-2uh`). Before this change the
  AST/scope layers looked a nested `defmodule Inner` up by its
  unqualified name (`Inner`), which is ambiguous when several outer
  modules each nest an `Inner`. An efficacy run against an app-shaped
  project surfaced sites being attributed to the wrong module and a
  nested module being matched by a bare `Inner` target. The fix qualifies
  nested modules by their full path (`Outer.Inner`) end to end:
  `MutagenEx.Ast.find_module_body/2` resolves `"Outer.Inner"` and rejects
  bare `"Inner"`; the scope resolver returns nested `%Scope{}` records
  under fully qualified atoms (`Outer`, `Outer.Inner`); and the enumerator
  emits sites only from the targeted block, never a sibling's AST.

- **App-shaped default timeout** (`mutagen-csv`). The previous
  `--timeout-ms` default of `5_000` ms was tuned for library-shaped
  projects. App-shaped (Phoenix/Ecto) suites pay a per-cycle setup +
  supplemental-test cost that routinely exceeds five seconds, so the old
  default spuriously classified live mutants as `:timeout`. The default
  is raised to `30_000` ms.

- **AST helper contract reconciliation** (`mutagen-2uh`). The lifted
  `MutagenEx.Ast` helpers (`alias_to_module/1`, `find_module_body/2`)
  remain the single canonical owners. Donor modules carry no private
  duplicate; the canonical owner `lib/mutagen_ex/ast.ex` may keep private
  `find_module_body` clauses as its recursive implementation. The
  donor-equivalence safety net asserts identical output for every input
  except the documented nested-module qualification carve-out.

## Decision

- **Qualify nested modules by full path at every boundary.** The AST,
  scope-resolution, and mutation-enumeration subjects all encode the same
  carve-out: a fully qualified target (`Outer.Inner`) resolves to the
  nested block; an unqualified inner name (`Inner`) does not match and
  returns `:module_not_found` / `:not_found`. See
  [mutagen.ast](../specs/ast.spec.md) r2/s5a,
  [mutagen.scope_resolution](../specs/scope_resolution.spec.md) r10/s10,
  and [mutagen.mutation_enumeration](../specs/mutation_enumeration.spec.md)
  r4/s4.
- **Default `Config.timeout_ms` to `30_000` ms.** The CLI default
  ([mutagen.cli](../specs/cli.spec.md)) and the pipeline contract
  ([mutagen.mutation_pipeline](../specs/mutation_pipeline.spec.md) r19)
  both record the `30_000` ms default and the app-shaped rationale. The
  value is a default only; it does not change the timeout mechanism (r4)
  or any classification contract, and callers override it per run.
- **Preserve the donor-equivalence safety net.** The pre-`.25` donor
  implementations stay as test fixtures so a future change to the lifted
  helpers cannot silently diverge from established behavior outside the
  documented carve-out.

## Consequences

**Positive**:

- App-shaped projects (the adoption target) stop seeing spurious
  `:timeout` verdicts and wrong-module site attribution — the two
  findings that motivated the epic.
- The branch-guard cross-cutting finding is resolved: the spec deltas
  record the behavior the children shipped, and this decision records why
  the qualification + default-raise posture was chosen.

**Negative / accepted**:

- Raising the default timeout makes a fully-surviving (slow) run take
  longer before it gives up on a genuinely hung mutant. This is the
  correct trade for app-shaped suites; library-shaped callers who want
  the old behavior pass `--timeout-ms 5000`.
- The nested-module qualification is a behavior change for any caller
  that previously relied on bare-`Inner` matching. That path was
  ambiguous and is intentionally removed; the fully qualified form is the
  only supported spelling.
