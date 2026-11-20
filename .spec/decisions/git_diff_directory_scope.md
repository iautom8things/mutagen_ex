---
id: mutagen.decision.git_diff_directory_scope
status: accepted
date: 2026-11-19
affects:
  - mutagen.git_diff
---

# Include directory entries in the Git diff scope

## Context

A symlink or gitlink can introduce code below a directory path with no
source-file extension. Case-insensitive checkouts can also map a tracked
path whose case differs from a configured root into that root.

## Decision

Resolve the project directory's symlinks before Git discovery. Require a Git
working tree and check every component of each diff root with lstat. Report
symlinks and gitlinks at or below the roots independently of their extensions.

When core.ignorecase is true, collect the repository diff and compare paths
in Elixir using case folding. This includes case-variant tracked paths without
relying on Git's pathspec case rules. Retain the tracked spelling in results.

## Consequences

Case-insensitive reads can reach the existing diff caps because of changes
outside the project. A missing or redirected root produces an explicit failure.
