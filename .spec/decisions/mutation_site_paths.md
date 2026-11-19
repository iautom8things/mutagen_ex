---
id: mutagen.decision.mutation_site_paths
status: accepted
date: 2026-11-19
affects:
  - mutagen.ast
  - mutagen.scope_resolution
  - mutagen.mutators
  - mutagen.mutation_enumeration
  - mutagen.mutation_pipeline
  - mutagen.json_schema
---

# Attach outcomes to the exact enumerated AST node

## Context

This decision revises the implementation described in
mutagen.decision.mutation_id_scheme_2 before it leaves the branch.
Several bare literals can share an inherited source position. The old
runner repeatedly swapped the first literal at that position.

## Decision

Record a path from the original file AST root when enumerating each site.
Use that path for the swap and verify that its leaf equals the original AST.
This also addresses two-tuple sites, which have no positional metadata.

Hash a project-owned encoding of the identity. Frame scalar payloads by tag
and byte length, encode floats as IEEE 754 binary64, frame containers by
element count, and sort maps by encoded key. Normalize file paths during
scope resolution. Keep only the parser's semantic `no_parens` flag for
dynamic remote receivers. The IDs represent parsed source syntax and
do not include expansion metadata.

Key bare literals by their parsed value, normalized parent, and local
child index. Key module-body sites by module and statement head. Use the
named function and declared arity across clauses, including named guards.
A static protocol or implementation gets its compiler module name.
Implementation resolution follows source aliases and implicit aliases from
preceding declarations. Names computed by macros are outside static analysis. A
definition inside a quote uses the enclosing unquoted context. A dynamic
definition name uses its normalized head as an identity and emits null
for the function. An implementation generated for several types shares
one source path and uses the list of implementation modules for identity.
When no single module can be named, its function is null.

Include report metadata on NDJSON end lines so early aborts carry the
same schema and ID markers as runs that reached start.

## Consequences

Inserting an earlier identical expression in a function can shift later
IDs and let an ID transfer to another occurrence. Consumers that persist
IDs should also save and compare `function` and `before_source`. Compare
schema, ID scheme, Elixir, and OTP versions. Formatter migrations that
rewrite parsed syntax change IDs. Earlier reports may carry verdicts for
a different site than the ID describes.
