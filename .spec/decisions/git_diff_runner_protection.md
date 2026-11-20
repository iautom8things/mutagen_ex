---
id: mutagen.decision.git_diff_runner_protection
status: accepted
date: 2026-11-19
affects:
  - mutagen.git_diff
supersedes:
  - mutagen.decision.git_diff_read_only
  - mutagen.decision.git_diff_tracked_scope
---

# Protect the runner while reading a Git diff

## Context

The diff reader chooses what an advisory run can inspect. A pull request
that hides its own changes loses its own advice.

## Decision

Protect the machine that reads the diff. Use Git with argument lists and
no shell. Reading a diff must execute no repository code and perform no
writes or reads outside the repository. Bound time and output. Return a
clean failure for input the reader cannot parse. Report skipped changes.

## Consequences

Keep the read-only and tracked-scope checks in place. Pull-request change
visibility has value for the advice, and resisting deliberate concealment
is outside the scope of this reader.
