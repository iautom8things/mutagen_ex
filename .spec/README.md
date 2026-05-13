# mutagen_ex — Specled Specs

This directory is the source of truth for **behavioral invariants** of
`mutagen_ex` (the `mix mutagen` mutation-testing tool). Implementation lives in
`lib/`; specs describe what the implementation must guarantee.

## Layout

```
.spec/
├── README.md          — this file
├── AGENTS.md          — instructions for AI agents working in this directory
├── specs/             — one .spec.md per subject (module, workflow, policy)
└── decisions/         — one .md per architectural decision (ADR-style)
```

## Subjects (`.spec/specs/*.spec.md`)

Each subject file has prose at the top describing intent, then three machine-
readable fenced blocks:

1. **`spec-meta`** — `id`, `kind` (`module` / `workflow` / `policy` /
   `integration`), `status` (`draft` / `accepted` / `deprecated`), `summary`,
   `surface` (file globs this subject covers), `decisions` (list of decision
   IDs this subject defers to).
2. **`spec-requirements`** — Behavioral invariants stated as falsifiable rules.
   Priority is `must` (system is broken without this) or `should` (strong
   expectation). Every requirement has a stable `id`.
3. **`spec-scenarios`** — Given/When/Then scenarios that demonstrate or refute
   a requirement. Each scenario `covers:` one or more requirement IDs.
4. **`spec-verification`** — Stubs naming the test or check that would prove a
   requirement holds. `execute: false` means the test does not yet exist.

## Decisions (`.spec/decisions/*.md`)

ADR-format markdown with frontmatter (`id`, `status`, `date`, `affects`) and
three sections: **Context**, **Decision**, **Consequences**. Subjects in
`specs/` reference decisions via the `decisions:` field in `spec-meta`.

## Verification command

The project verification command is:

```
mix test
```

This compiles the project (`mix test` runs the compile step) and exercises the
test suite, including the spec-verification stubs once they are wired up.
Stricter pre-merge check:

```
mix compile --warnings-as-errors && mix test
```

## Conventions

- Subject IDs use dotted notation rooted at `mutagen`: `mutagen.cli`,
  `mutagen.mutators`, `mutagen.mutation_pipeline`, etc. The leading namespace
  is `mutagen` (the action) rather than `mutagen_ex` (the package), because
  the user-facing command is `mix mutagen` and the action vocabulary is more
  natural in the specs.
- Decision IDs use `mutagen.decision.<short_name>` for the same reason.
- Requirements within a subject use `<subject_id>.r<n>` (e.g.
  `mutagen.cli.r1`). Scenarios use `<subject_id>.s<n>`. Verification stubs use
  `<subject_id>.v<n>`. Stable IDs let other documents reference invariants
  without quoting the prose.
- A requirement is **falsifiable** when you can describe a concrete state in
  which it would be false. Implementation details (e.g. "uses `:cover`") are
  not falsifiable; behavioral statements (e.g. "after a coverage run, calling
  `:code.which/1` on every coverage-instrumented module returns a non-
  `cover_compiled` value") are.
