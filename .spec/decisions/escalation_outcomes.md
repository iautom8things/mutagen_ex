---
id: mutagen.decision.escalation_outcomes
status: accepted
date: 2026-11-19
affects:
  - mutagen.mutation_pipeline
  - mutagen.json_schema
---

# Retain terminal outcomes during test escalation

## Context

Automatic selection probes new test files in the host VM. A rejected file
can leave state behind, and an infinite loop in one pass can look like a
survivor if a later pass replaces its timeout.

## Decision

Escalate only survivors and uncovered sites. Keep the verdict and step for
every terminal outcome. Monitor the test group leader so a crash becomes a
red baseline or a killed mutant.

Restore the OS environment and the environment of every loaded application
after a candidate probe. Apply the load-time changes of accepted files during
their own pass. Record drops after a load attempt and mark verdicts from that
step onward because other state can persist.

Give each candidate ten times the narrow baseline duration, with a thirty-second
floor capped by the configured host boot and mutant timeout ceilings. Mark
every abort document incomplete.

## Consequences

A timeout stays visible and unevaluated. Readers can identify verdicts made
after a rejected candidate may have changed the VM. The runner cannot undo
every side effect of a test file, including writes to persistent terms.
