---
id: mutagen.decision.git_diff_tracked_scope
status: accepted
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
metadata. Check root directories before and after the diff. Report index
links in scope regardless of their diff status.

Use NFC matching and fold case when either the Git setting or a filesystem
probe indicates an insensitive checkout. Read NUL-delimited index and base
tree metadata to discover the exact tracked root spellings. Only matching
metadata counts against the output cap. Pass those spellings as literal
pathspecs before Git applies rename detection or generates patches. This
replaces whole-repository patch generation on case-insensitive checkouts.

## Consequences

Unrelated patches stay outside the output, file, and working-file caps. A
move into scope is an addition. The gate consumes the tracked spelling in
each result key and treats a skipped link as an incomplete read.
