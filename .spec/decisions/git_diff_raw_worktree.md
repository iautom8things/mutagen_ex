---
id: mutagen.decision.git_diff_raw_worktree
status: accepted
date: 2026-11-19
affects:
  - mutagen.git_diff
---

# Compare source bytes in the caller's project

## Context

Repository attributes and content detection can hide changed source from the
gate or move its reported line numbers. A project can also live below the
repository root. Container CI often shares a checkout with another user.

## Decision

Require Git 2.41 or newer. Pin the worktree to the directory discovered from
its Git metadata and use Git's project prefix for literal path lookups. Read
attributes from the empty tree, disable checkout conversion defaults, and
force text patches. Refuse repository info attributes before diffing. Report
changed entries that cannot provide source ranges, and check ranges against
the raw working files.

Keep standard global config readable so Git can honor the administrator's
or runner's safe.directory entries. Git still makes the ownership decision.
Discard inherited Git overrides, disable system config, and pin relevant
global and local config at command scope. Continue refusing partial clones.

## Consequences

Projects with repository info attributes must clear them before this read.
Projects that use on-disk text conversion can see extra ranges because the
reader compares their working bytes. A CI job with an untrusted checkout
must use its owning user or configure Git's ownership exception itself.
