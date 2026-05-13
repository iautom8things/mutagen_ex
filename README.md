# mutagen_ex

Mutation testing for Elixir, designed for in-process operation against a chosen
scope and a cited test set. Emits a single JSON document describing every
mutation site, its classification, and the surrounding run metadata.

> **Status: pre-v1 scaffolding.** This README is a skeleton; the full surface
> ships in S8. Until then, the authoritative documentation is `mix help
> mutagen` and the specs under `.spec/`.

## Quick look

```bash
mix mutagen --scope lib/foo.ex --tests test/foo_test.exs
```

See `mix help mutagen` for the complete flag surface, exit codes, and known
caveats.

## Specs

The behavioural contract for `mutagen_ex` lives in `.spec/`:

- `.spec/specs/cli.spec.md` — `mix mutagen` command surface
- `.spec/specs/mutation_pipeline.spec.md` — orchestration state machine
- `.spec/specs/mutators.spec.md` — mutator catalog and predicates
- `.spec/specs/json_schema.spec.md` — v1 output document shape
- `.spec/decisions/` — durable architectural decisions

When the implementation and the specs disagree, fix the spec first (see
`.spec/AGENTS.md`).

## Development

```bash
mix compile --warnings-as-errors
mix test
```
