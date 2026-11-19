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

The outer group's fingerprint includes the boundary of a nested module
or definition. The nested contents hash in their own groups. Planning
hashes only groups that own planned entries and the corresponding keys
in the base.

Group fingerprints cover local syntax. Edits to module attributes,
`defguard`, `defmacro`, `defdelegate` targets, `alias`, `import`,
`use` options, and `defstruct` defaults can affect runtime behavior
while yielding zero planned runtime sites. A private helper's edit
scopes the helper's own sites on touched lines. Its callers keep their
fingerprints.

Pure deletions can yield zero planned sites, including removals within
a function, deleted clauses, and dropped guards. The diff producer
discards hunks with zero new-side lines. Wiring must preserve those
hunks' new-side anchors and supply the existing lines on either side
as changed spans. For Git's `+N,0`, intersect the lines `N` and `N+1`
with the current file's existing line numbers. A surviving
adjacent site remains subject to the group fingerprint comparison.

The runtime rule is syntactic. A named `def` called only during
compilation still qualifies and can become an uncovered blocker. Code
inside `unquote` within `quote` falls outside the runtime plan even
when a runtime call evaluates it.

An outer mutation site can depend on nested syntax. A site ID can
include the whole expression or, for a bare literal, its parent. Keep
that syntax in the outer fingerprint when the ID includes it. Swapping
two nested bodies under identical outer conditions could otherwise
transfer an outer ID without changing its fingerprint.

Planning keeps each group's fingerprint inputs and computes the hash
when a comparison needs it. A new file or a group absent from the base
can enter scope without hashing. Callers can resolve a planned group's
fingerprint when they need it for an acceptance check.

If a planned ID is absent from the run output and its effective line
was covered, A4 records `:not_run`. This includes sites the runner
dropped after `site_node_not_found` or `ast_cache_miss` warnings.
Preserve the `+N,0` anchors before deciding whether the diff is empty.
At the start of a file this selects the first remaining line. At EOF it
selects the last remaining line. An empty new file has no adjacent span.
