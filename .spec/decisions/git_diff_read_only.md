---
id: mutagen.decision.git_diff_read_only
status: accepted
date: 2026-11-19
affects:
  - mutagen.git_diff
---

# Read the working-tree diff without Git helpers

## Context

The CI gate needs new-side changed lines and the merge-base blob for each
changed file. The working tree can contain uncommitted edits, intent-to-add
files, and filenames with whitespace or non-ASCII bytes. Git may otherwise
run configured programs when it reads and compares these files.

## Decision

Run Git with separate arguments and resolve the caller's ref to a commit ID.
Read NUL-delimited raw and numstat records with zero-context patches in one
invocation. Use numstat to skip changes to file timestamps alone, which can
have a raw record without a patch. Use literal paths and a separate
tree-entry lookup to distinguish an absent base file from a failed blob read.

Disable optional writes, fetching, and subprocess hooks. Override Git's
diff and show defaults and disable configured diff and checkout-conversion
programs before reading the working tree. Bound the bytes collected from Git
and the number of returned diff entries.

## Consequences

The reader preserves Git's rename pairing and literal path bytes without
depending on the presentation of patch filenames. It returns a structured
failure if history is unavailable or a result exceeds either cap. The local
configuration must stay stable while the reader performs the Git calls.
