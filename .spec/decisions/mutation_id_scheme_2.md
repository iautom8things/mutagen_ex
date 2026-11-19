---
id: mutagen.decision.mutation_id_scheme_2
status: accepted
date: 2026-11-19
affects:
  - mutagen.mutators
  - mutagen.mutation_enumeration
  - mutagen.mutation_pipeline
  - mutagen.json_schema
---

# Identify mutation sites by definition, expression, and occurrence

## Context

This decision supersedes mutagen.decision.content_addressed_ids. Nested
position metadata made IDs change after an unrelated insertion. Repeated
expressions in one file shared an ID, which made survivor comparisons
ambiguous.

## Decision

Keep the `{relative_file}:{hash}:{mutator}` string shape. Hash the
`{enclosing, normalized_node, ordinal}` term. The enclosing definition
is `{module, name, declared_arity}` or nil outside a definition. Count
identical nodes for each mutator in file walk order before filtering, across
clauses of one function. Emit a site once for overlapping scopes.

Discard AST metadata recursively except for an allowlist. Keep `no_parens`
for dynamic receivers because a zero-argument call and a map field lookup
can have the same AST shape. Drop it for statically named modules, where
the formatter adds parentheses to the same call. Keep `alias`, `context`, `counter`, `imports`, and
`if_undefined` for name and variable resolution in quoted ASTs.
`ambiguous_op` only rejects ambiguous calls with a variable in scope.
When the call compiles it resolves the same way as the explicit call, so
discard the flag to match the formatter's rewrite. `assoc` records the
location of `=>`. `delimiter`, `format`, `indentation`, `token`,
`from_brackets`, and `from_interpolation` describe presentation.
Sigil names, modifiers, and parsed content stay in the AST. The parser
already accounts for heredoc indentation when constructing the content.

Use the BEAM's built-in MD5 with deterministic term encoding. The full
32-bit `phash2` range collides for `x + 9264` and `x + 11128` at ordinal
zero in `Probe.f/1` on OTP 28.5. MD5 makes accidental collisions far less
likely and adds no runtime dependency. These hashes identify source sites
and carry no cryptographic security guarantee.

Emit report schema version 2 and `meta.id_scheme: "2"`. Include the
enclosing function as `Mod.fun/arity` or null on aggregate and streamed
results. Schema 1 IDs and reports cannot be compared with schema 2.

## Consequences

An expression edit, function rename, arity change, or file rename changes
its ID. Inserting an identical earlier expression in the same enclosing
definition shifts the later ordinals. Sites outside functions share a
file-wide ordinal group for each normalized node and mutator. IDs refer to
the parsed site and can stay fixed when an edit elsewhere changes behavior.

The runner still needs its fallback for bare literal nodes, which lack
their own positions and are omitted from the path index.
