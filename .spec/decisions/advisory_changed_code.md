---
id: mutagen.decision.advisory_changed_code
status: accepted
date: 2026-11-19
affects:
  - mutagen.cli
  - mutagen.git_diff
  - mutagen.scope_resolution
  - mutagen.test_selection
  - mutagen.coverage
  - mutagen.mutation_pipeline
  - mutagen.json_schema
---

# Report changed-code runs as advisory evidence

## Context

Local changes can include untracked files. A narrow test selection can
miss existing coverage, and additional files can fail or hang when run
on original code.

## Decision

Report the current run without keeping state in the repository. Exit 0
when the run completes, including when its evidence is incomplete.
Exit 2 for a tool abort. Fingerprints compare source groups internally.

Look for tests for every unresolved runtime site. Cap the text search
separately per function. Try each new file with a deadline on original
code. When a batch is red, retain a green subset in score order. Keep
the narrow report if escalation cannot complete.

## Consequences

The report preserves the narrow baseline and the measurements from
each additional step. It identifies changed lines that map to no
runtime site so the reader can inspect what the run covers.

## Quiet changed-code defaults

The default run uses the convention tests and test files changed in the
diff. Pass `--escalate` to search for more tests. The changed-code summary
shows survivors whose expression span intersects a changed line. Entries
sort by path and line within each confidence group, with high confidence
first. The remaining survivors stay in the JSON. Audit runs keep the
provisional whole-file ordering.
