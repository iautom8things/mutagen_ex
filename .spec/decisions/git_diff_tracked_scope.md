---
id: mutagen.decision.git_diff_tracked_scope
status: superseded
superseded_by: mutagen.decision.git_diff_runner_protection
date: 2026-11-19
affects:
  - mutagen.git_diff
---

# Resolve tracked root spellings before generating patches

## Context

A checked-out submodule is a real directory. An index link that has no diff
can still let an edit outside a source root introduce code under it. The
Git config can disagree with the disk's case rules, and a whole-repository
patch can exhaust the reader's limits on unrelated changes.

## Decision

Reject a submodule checkout and any diff root whose components contain Git
metadata. Git's superproject lookup needs an exact index match, which a
case-insensitive disk can defeat. Also treat a Git directory under another
Git directory's modules directory, or a folded and NFC-normalized gitlink in
any enclosing checkout, as a submodule. Reject a project directory reached
through a symlink inside the checkout. For a nested project, also reject a
tracked symlink that resolves to the project directory or an ancestor, since
the caller may pass a path the shell already resolved. Report index links in
scope regardless of their diff status.

Check the root components and the directories of in-scope changed paths
before and after the diff. A directory that keeps its type and identity has
only gained or lost entries, as when an editor saves a temporary file. Retry
the whole read once in that case and fail if anything changes again.

Use NFC matching and fold case when either the Git setting or a filesystem
probe indicates an insensitive checkout. Read NUL-delimited index and base
tree metadata to discover the exact tracked root spellings. Only matching
metadata counts against the output cap. Pass those spellings as literal
pathspecs before Git applies rename detection or generates patches. This
replaces whole-repository patch generation on case-insensitive checkouts.

## Consequences

Unrelated patches stay outside the output, file, and working-file caps. A
move into scope is an addition. The planner uses the tracked spelling in
each result key. It treats a skipped entry as an incomplete read and names
the reason and path, because a committed symlink under a root is always
listed. An enclosing checkout that Git refuses for ownership fails the read.
A legitimate tracked link to a nested project directory also fails it, with
a distinct cause. Continuous writes into a scanned directory fail after one
retry.
