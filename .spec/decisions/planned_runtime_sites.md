---
id: mutagen.decision.planned_runtime_sites
status: accepted
date: 2026-11-19
affects:
  - mutagen.mutation_enumeration
  - mutagen.mutators
---

# Scope planned mutation sites by group fingerprint

## Context

An earlier identical expression can inherit a later expression's ID.
Moving or formatting an unchanged function can put its sites on changed
lines.

## Decision

Use the existing site ID group key. For each group, hash the list of its
clause or module-body statement ASTs in walk order. Normalize each AST with
the ID metadata rules and hash the canonical encoding with MD5. Compare
the same group key in the current and base versions of the file. An entry
is in scope when its span overlaps changed lines and its group fingerprint
changes or the base lacks that group.

Plan entries without coverage and retain skips. An entry is a runtime
site when its enclosing definition is a named `def` or `defp` with a
non-null function and the entry is outside `quote`.

## Consequences

An edit within a group changes the fingerprint when it changes the
normalized ASTs. Moving a function preserves the fingerprint and the
paths within its clauses. The runner addresses each site by its
path from the current file root. Coverage is needed to decide whether
an absent runtime outcome is uncovered.
