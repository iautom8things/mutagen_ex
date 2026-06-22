# Agent Instructions for `.spec/`

You are an AI agent making changes to `mutagen_ex`. This file tells you how to
work with the `.spec/` directory.

## What `.spec/` is

The source of truth for **behavioral invariants** of `mutagen_ex`. Specs are
the contract; `lib/` and `test/` are the implementation. If they diverge, the
spec is wrong, the code is wrong, or both — never silently update one to match
the other.

## Read before writing code

Before implementing a feature or fixing a bug, read the relevant
`.spec/specs/*.spec.md` file. The `spec-requirements` block names the rules
your change must satisfy. The `spec-scenarios` block names cases your change
must handle. The `spec-verification` block names the tests that prove it.

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

## Verification command

Run this to verify your changes pass:

```
mix test
```

Pre-merge stricter check:

```
mix compile --warnings-as-errors && mix test
mix spec.check
```

`spec_led_ex` is now a required `:dev`/`:test` dependency (see
`.spec/decisions/adopt_specled_tooling.md`). `mix spec.check` is part of the
local gate — it is no longer optional. The `mix spec.validate` task checks the
authored corpus against the SpecLedEx schema; `mix spec.check` additionally
checks `realized_by:` bindings against the code.

Schema notes (SpecLedEx, not the original bespoke shape):

- `spec-scenarios` entries use `given:` / `when:` / `then:` arrays.
- `spec-verification` entries name a `command:` and a `target:` path (the
  older `execute:` / `source_file:` stub form is not accepted).
- Subjects use `status: active` once validated (not `accepted`).
- Each subject carries a `realized_by.api_boundary:` list of MFAs. Use
  `mix spec.suggest_binding` to draft one.

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
superseded` and reference the replacement.
