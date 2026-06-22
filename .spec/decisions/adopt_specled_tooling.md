---
id: mutagen.decision.adopt_specled_tooling
status: accepted
date: 2026-06-22
affects:
  - mutagen.ast
  - mutagen.cli
  - mutagen.coverage
  - mutagen.json_schema
  - mutagen.mutation_enumeration
  - mutagen.mutation_pipeline
  - mutagen.mutators
  - mutagen.scope_resolution
  - mutagen.test_selection
---

# Adopt the spec_led_ex toolchain (reverse the tooling-optional stance)

## Context

The `.spec/` corpus was authored by hand during the `mix mutagen` build as a
bespoke, tooling-agnostic convention. The original `.spec/AGENTS.md` made the
`spec_led_ex` dependency explicitly optional:

> "If the project ships a `mix spec.check` task (via `specled_ex` dependency),
> run that too. Otherwise, the `spec-verification` block's `command:` and
> `source_file:` stubs serve as the executable contract."

No bw ticket ever tracked SpecLedEx adoption — the absence was by design, not
an abandoned effort. The convention worked: 9 subjects, 18 decisions, and
`mix test` as the contract.

The cost of staying tooling-optional is that nothing mechanically enforces the
triangle. Specs can drift from code silently; requirements can be deleted
without a guardrail; bindings between subjects and MFAs are not checked. As
`mutagen_ex` approaches 1.0 and downstream adoption, the team chose to make the
spec corpus machine-checkable.

## Decision

Adopt `spec_led_ex` as a `:dev`/`:test` dependency
(`github: "iautom8things/specled_ex"`, pinned to `main` until a Hex release
exists) and migrate the hand-authored corpus to the SpecLedEx schema:

- `spec-scenarios` blocks move to the given/when/then array shape.
- `spec-verification` blocks move from `execute:`/`source_file:` stubs to
  `command:`/`target:` entries.
- Subjects graduate `status: draft` → `status: active` once they validate.
- Each subject gains a `realized_by.api_boundary:` binding (phase2).

The 18 existing decision files already match the SpecLedEx decision schema and
are not migrated.

Severities start SOFT (warnings) during adoption; graduating them to `error`
is deferred to a follow-on epic once the triangle is green.

## Consequences

- `.spec/config.yml` now exists and `mix spec.check` is part of the local gate.
- `.spec/AGENTS.md` is updated: the dependency is required, not optional, and
  the schema notes for scenarios/verification are corrected.
- The deeper `realized_by` tiers (implementation, expanded_behavior, use,
  typespecs) and the coverage triangle (`mix spec.cover.test`) are NOT opted
  into by this work; their detectors will report `detector_unavailable`, which
  is expected and silent. They remain available for a future phase.
- This decision supersedes the "Otherwise…" clause of the original
  tooling-optional guidance. It does not delete the bespoke convention's
  intent — falsifiable, repo-resident, behavior-first specs — it mechanizes it.
