---
id: mutagen.decision.f19_descoped
status: accepted
date: 2026-05-15
affects:
  - mutagen.test_selection
---

# F19 (TestSelector.scan_for_tag cache integration) descoped from .25

## Context

The original `mutagen-wrd.25` ticket bundled eight review findings
(F15/F16/F18/F19/F20/F21/F40/F45) into one mega-ticket. F19 specifically
flagged that `MutagenEx.TestSelector.scan_for_tag/2` walks the entire test
tree on every `--tests tag:foo` invocation, reading each test file from
disk for tag matching — duplicating I/O the `AstCache` should be able to
serve.

During `/mega-plan` refinement, three independent inputs converged:

- **Architecture chicken-and-egg.** `lib/mix/tasks/mutagen.ex` invokes
  `phase_tests` (which resolves the test set, including tag-based selection)
  BEFORE `phase_ast_cache` (which loads files into the cache). The cache
  literally does not exist when `scan_for_tag` runs.
- **Scope-auditor flag** ([04c-scope-audit.md]): the architect proposed
  `:persistent_term` as a workaround. The auditor noted this introduces a
  second cache mechanism, which the spec did not ask for — the spec said
  "Extend `AstCache` to cover ... cited test files", singular cache.
- **Testability flag** ([04b-testability-review.md]): `:persistent_term`
  is global across the VM. Two `async: true` tests sharing the same
  fixture would race on the global, breaking test isolation. The project's
  test suite makes liberal use of `async: true`.

The user was asked during mega-plan Phase 5 to choose between:

1. Descope F19 to a follow-up.
2. Re-order `phase_tests` and `phase_ast_cache` (closes F19 but introduces
   ripple effects in the test-filter pipeline).
3. Accept the `:persistent_term` workaround.

The user chose option 1.

## Decision

F19 is descoped from `mutagen-wrd.25`. F18 (`Baseline.detect_async_modules/1`
cache consumer) stays in `.25` and is closed by stage S2 via
`mutagen.decision.ast_cache_facade_preserved`.

F19 moves to a new follow-up ticket `mutagen-wrd.25-fu1` (created during
`/distill`) with the following notes:

- **Suggested approach**: re-order `phase_tests` and `phase_ast_cache` so
  the cache can carry tag-resolved test files. Investigate ripple effects
  on test-filter pipeline first.
- **Alternative**: cache TestSelector results in a per-run map threaded
  through cfg (not `:persistent_term`).
- **Cost bound**: F19 manifests only when `--tests tag:foo` is used.
  Today's test-resolution code is correct (just slow). The performance
  impact is bounded and small in typical workflows.

## Consequences

**Positive:**
- `.25`'s scope stays tight; no second cache mechanism introduced.
- The cleaner long-term fix (phase reorder) can be investigated without
  rushing under `.25`'s constraints.
- Test isolation invariant preserved — no `:persistent_term` footgun.

**Negative:**
- F19's I/O cost remains unchanged until `.25-fu1` lands. For
  `--tests tag:foo` workflows, this is one extra full-test-tree walk +
  parse per invocation. Bounded; not a correctness issue.

## Related

- mutagen.coverage — owns the AstCache contract (extended in `.25` for F18).
- mutagen.decision.ast_cache_facade_preserved — the F18 side of the fork.
- bw ticket `mutagen-wrd.25-fu1` — tracks F19.
