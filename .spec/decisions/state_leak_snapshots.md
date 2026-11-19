---
id: mutagen.decision.state_leak_snapshots
status: accepted
date: 2026-11-19
affects:
  - mutagen.mutation_pipeline
---

# Report new VM state by name

## Context

The count-based check in mutagen.decision.timeout_handling marked later
results tainted when OTP cached a module's logger configuration. The Elixir
compiler also adds a persistent term on first use. Counts cannot identify
the leaked state or detect a new key if an existing key was removed.

## Decision

Compare registered process names, ETS table identities, and persistent term
keys. Ignore `{:logger_config, module}` and `:elixir_erl_compiler` in the
persistent term snapshot. Warn with the names or keys of new entries.
Carry taint forward for the rest of the run since later tests may read
the leaked state.

## Consequences

The warning identifies state a maintainer can investigate. The snapshots
remain VM-wide. Concurrent activity can contribute entries, and changing
the value under an existing key does not count as a new entry.
