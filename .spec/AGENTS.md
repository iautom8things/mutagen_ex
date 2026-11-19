# Agent Instructions for `.spec/`

You are an AI agent making changes to `mutagen_ex`. This file tells you how to
work with the `.spec/` directory.

## What `.spec/` is

The source of truth for **behavioral invariants** of `mutagen_ex`. Specs are
the contract; `lib/` and `test/` are the implementation. If they diverge, the
spec is wrong, the code is wrong, or both. Resolve the discrepancy in the same change.

## Read before writing code

Before implementing a feature or fixing a bug, read the relevant
`.spec/specs/*.spec.md` file. The `spec-requirements` block names the rules
your change must satisfy. The `spec-scenarios` block names cases your change
must handle. ExUnit `spec:` tags identify the tests that prove each
requirement.

If you discover that the spec is incomplete or wrong: **update the spec first**
in the same change. Do not write code that violates a current invariant
without an explicit spec edit (and a corresponding decision file, if the
change is architectural).

## Write specs as falsifiable rules

A requirement is good if a reviewer can describe a concrete state where it
would be false. Examples:

- ❌ Bad: "The mutation runner uses `:cover` cleanly."
- ✅ Good: "After `MutagenEx.CoverageRunner.run/1` returns, `Process.whereis(:cover_server)` is `nil`."
- ❌ Bad: "Mutation IDs are stable."
- ✅ Good: "Running `mix mutagen --scope X` twice on the same source produces byte-identical `mutation.results[].id` values."

Avoid statements about how the code is structured (those go in decisions or
emerge from `lib/`). Specs describe observable behavior.

## Prove the requirement with ExUnit

Tag an assertion that would fail if the requirement broke. Use a literal
`@tag spec: "mutagen.<subject>.r<n>"` and call the production entry point.
For multiple requirements on one test, use a list of IDs. Use `@describetag`
or `@moduletag` when all tests in that group prove the same requirement.
Ancora traces calls from the tagged tests, their setup, and reachable helpers.
Source and documentation checks may carry a tag when the requirement
itself is structural. Keep runtime requirements anchored to production calls.

Tags drive proof. The optional `spec-verification` block supports
`kind: tagged_tests`. Use exact repo-relative file paths in `surface:`.
Keep active specs at `status: active` and use arrays for scenario
`given:`, `when:`, and `then:` fields.

## Verification commands

Run the proving tests after editing a contract. Check the branch before merging:

```sh
mix spec.validate --strict
mix spec.check --base HEAD
target=hardening/epic
mix spec.check --base "$(git merge-base HEAD "$target")"
make smoke
mix test.integration
```

Ancora reads source and git history. ExUnit runs the assertions. There is no
state file to update. Read `mix spec.check --verbose` for informational
findings and use `mix spec.status` to inspect subject bindings. An explicit
`--base` compares directly with the supplied commit. The local default
target is `origin/main`.

Review drift, growth, and shrink against the requirement or scenario edit
that explains them. If the change was accidental, restore the original
behavior or proof. For an uncovered library file, add a test that genuinely
exercises it. If Ancora cannot see the call, document the reason in an exact
override in `config.yml`. Squash merges drop commit trailers, so put required
severity exceptions in config with a reason.

## Linking

Subjects link to decisions via the `decisions:` field in `spec-meta`. Decisions
link back to subjects via the `affects:` field in frontmatter. Keep these
bidirectional links in sync when you add or change either side.

## Conventions

- Subject IDs are dotted under `mutagen` (the action): `mutagen.cli`,
  `mutagen.mutators`, etc. Filename matches the trailing segment:
  `.spec/specs/cli.spec.md` for `mutagen.cli`.
- Decision IDs are `mutagen.decision.<short_name>`. Filename matches:
  `.spec/decisions/in_process_pipeline.md` for
  `mutagen.decision.in_process_pipeline`.
- Module namespace in `lib/` is `MutagenEx.*`. Mix task module is
  `Mix.Tasks.Mutagen`. User-facing command is `mix mutagen`.
- Internal naming convention reminder: the Hex package is `mutagen_ex` (the
  `_ex` suffix disambiguates from non-Elixir tools named "mutagen"). The
  module namespace mirrors that: `MutagenEx.*`. The CLI verb (`mix mutagen`)
  drops the suffix because the namespace already disambiguates it. Spec IDs
  use the verb (`mutagen.*`) for the same reason.

## When to add a decision

Add a decision file (`.spec/decisions/<short_name>.md`) when:

- You make a non-local architectural choice that affects multiple subjects.
- You resolve a tension between competing requirements.
- You accept a known trade-off (e.g., taking a coarser signal in v1 in
  exchange for simpler implementation).

Decisions are durable; do not delete them when superseded. Mark `status:
superseded` and set `superseded_by:` to the new decision ID. Keep the
original body and record the change in the new decision.
