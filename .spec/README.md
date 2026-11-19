# mutagen_ex specs with Ancora

This directory is the source of truth for **behavioral invariants** of
`mutagen_ex` (the `mix mutagen` mutation-testing tool). Implementation lives in
`lib/`. Specs describe what the implementation must guarantee.

## Layout

```
.spec/
├── README.md          — this file
├── AGENTS.md          — instructions for AI agents working in this directory
├── specs/             — one .spec.md per subject (module, workflow, policy)
└── decisions/         — one .md per architectural decision (ADR-style)
```

## Subjects (`.spec/specs/*.spec.md`)

Each subject file has prose describing its intent and YAML fenced blocks:

1. `spec-meta` identifies the subject and records its kind, status, summary,
   owned files, and decision IDs. Use `active` for a current subject. List
   exact repo-relative files in `surface:`. The list determines which
   derived changes are primary.
2. `spec-requirements` contains falsifiable statements with stable IDs and
   `must` or `should` priority.
3. `spec-scenarios` gives concrete cases. Each scenario names one or more
   requirement IDs in `covers:` and uses arrays for `given:`, `when:`, and
   `then:`.

Ancora derives bindings from literal ExUnit `spec:` tags and the production
calls those tests make. Tag requirement IDs. Tags also work without a
`spec-verification` block. If you add one, use `kind: tagged_tests`, a test
path in `target:`, and requirement IDs in `covers:`.

## Decisions (`.spec/decisions/*.md`)

Decisions use YAML frontmatter with `id`, `status`, `date`, and `affects`.
They have Context, Decision, and Consequences sections. Subjects link back
through `decisions:` in `spec-meta`. For a replacement, add a decision with
`supersedes:` and update only the old decision's supersession metadata.

## Verification

```sh
mix spec.validate --strict
mix spec.check --base HEAD
mix spec.check --base <target-ref>
mix test
```

The first command checks the corpus. The two diff checks compare against
the working tree's latest commit and the target branch's merge base,
respectively. Run the tests separately. See [the agent guide](AGENTS.md) for
the pre-merge gate and [the migration decision](decisions/ancora_migration.md)
for inherited proof gaps.

## Conventions

- Subject IDs use dotted notation rooted at `mutagen`: `mutagen.cli`,
  `mutagen.mutators`, `mutagen.mutation_pipeline`, etc. The leading namespace
  is `mutagen` (the action) rather than `mutagen_ex` (the package), because
  the user-facing command is `mix mutagen` and the action vocabulary is more
  natural in the specs.
- Decision IDs use `mutagen.decision.<short_name>` for the same reason.
- Requirements within a subject use `<subject_id>.r<n>` (e.g.
  `mutagen.cli.r1`). Scenarios use `<subject_id>.s<n>`. Stable IDs let
  other documents reference invariants without quoting the prose.
- A requirement is **falsifiable** when you can describe a concrete state in
  which it would be false. Implementation details (e.g. "uses `:cover`") are
  not falsifiable; behavioral statements (e.g. "after a coverage run, calling
  `:code.which/1` on every coverage-instrumented module returns a non-
  `cover_compiled` value") are.
