---
id: mutagen.decision.advisory_only
status: accepted
date: 2026-11-19
affects:
  - mutagen.cli
  - mutagen.json_schema
supersedes:
  - mutagen.decision.no_pretty_output_v1
---

# Advisory only, no repository state

## Context

CI state files create churn in the repository. Removing the generated
state.json was also a reason to move the spec tooling to Ancora. Mutation
results describe what the selected tests observed in one run.

## Decision

Mutagen gives advice for each change and supports whole-module audits of
tests that execute code without checking its behavior. Each report stands
on its own. Exit 0 covers complete and incomplete reports. Exit 2 means the
tool aborted. CI can attach the JSON and optional Markdown report.

Accepted-entries files, baselines that compare mutation runs, comparisons
with previous reports, enforce mode, and blocking exit codes are out of scope.

## Consequences

If a future need calls for explicit acknowledgements, prefer reading a
commit-message trailer from Git history. The current implementation reads
no acknowledgement data. The JSON remains the CLI's stdout document.
