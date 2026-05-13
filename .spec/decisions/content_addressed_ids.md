---
id: mutagen.decision.content_addressed_ids
status: accepted
date: 2026-05-13
affects:
  - mutagen.mutators
  - mutagen.json_schema
---

# Mutation IDs are content-addressed by AST hash

## Context

The verifier judge LLM consumes the JSON output and may compare results
across runs (e.g., "did the same mutation survive last week?"). For that
comparison to be meaningful, the same mutation site must produce the same
ID across runs — even if the source file's formatting changed.

A naive `{file}:{line}:{col}:{mutator}` ID format would be unstable: running
`mix format` re-flows code and shifts every line/column. Two adjacent runs
on the same logical code, one before and one after `mix format`, would
produce disjoint ID sets.

The red-team's H-T3 finding called this out explicitly: "Mutation IDs
unstable across `mix format`."

## Decision

Mutation IDs use the format:

```
{relative_file}:{ast_hash}:{mutator_name}
```

Where:

- `relative_file` is the path relative to the project root.
- `ast_hash` is `:erlang.phash2/2` of the **normalized AST node**:
  metadata keywords `:line`, `:column`, `:end_line`, `:end_column` are
  stripped before hashing. Other metadata (e.g., `:context`) is preserved.
- `mutator_name` is the snake_case atom name (`:arith`, `:case_drop`).

Auxiliary `line` and `column` fields remain in the JSON's
`mutation.results[i]` for human debugging — they just don't participate in
the ID.

## Consequences

**Positive**:

- IDs are stable across `mix format`: the same AST normalizes to the same
  hash regardless of source whitespace.
- IDs are also stable across `mix format` minor-version differences,
  because we hash the AST shape, not the rendered source.

**Negative**:

- `:erlang.phash2/2` has a finite range (32-bit). Collision probability
  within a single file's mutation set is negligible in practice but not
  zero. If a collision occurs, two distinct sites would map to the same
  ID. We accept this; the alternative (SHA-256) is overkill for the scale
  involved (typically a few hundred sites per file).
- Migrating to a different hash function later is a schema break (it
  changes IDs across runs). The `version: "1"` field exists precisely for
  this kind of evolution; document the migration if it ever happens.
