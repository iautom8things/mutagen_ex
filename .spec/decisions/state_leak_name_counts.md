---
id: mutagen.decision.state_leak_name_counts
status: accepted
supersedes: mutagen.decision.state_leak_snapshots
date: 2026-11-19
affects:
  - mutagen.mutation_pipeline
---

# Count ETS growth by name

## Context

Connection pools replace unnamed ETS tables as connections cycle.
Comparing table identities marked the replacements as leaks even while
the number of tables stayed flat. An explicit Logger module level uses
the same key as the automatic cache.

## Decision

Compare ETS name counts, registered process names, and persistent term
keys. Report positive deltas by name. Ignore the Elixir compiler key and
new Logger keys for modules without an explicit level. Reuse the last
after-snapshot in serial runs so only the first tested site takes two.

## Consequences

A replacement under the same name produces no warning. An extra table
under a name records growth even when a table under another name goes
away. Taint remains sticky. Snapshots are VM-wide and count net changes
between observation points.
