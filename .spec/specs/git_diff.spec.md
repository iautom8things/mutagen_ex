# mutagen.git_diff

This library reads changed source lines and their merge-base versions for the
CI gate. `invalid_since_ref` and `diff_unavailable` are reserved CLI abort
reasons for a later slice. The CLI does not emit them in this slice.

```spec-meta
id: mutagen.git_diff
kind: module
status: active
summary: Reads changed lines and base blobs from Git for a later CI gate.
surface:
  - lib/mutagen_ex/git_diff.ex
decisions:
  - mutagen.decision.git_diff_read_only
```

```spec-requirements
- id: mutagen.git_diff.r1
  priority: must
  statement: |
    changed_lines/2 returns the merge-base and HEAD commit IDs and inclusive
    new-side ranges from zero-context hunks in the working-tree diff. Only
    added, modified, or renamed regular .ex files inside the configured roots
    contribute ranges. The default root is lib. Deletion-only hunks, binaries,
    mode-only changes, timestamp-only changes, and untracked files contribute
    no ranges. Intent-to-add files can contribute ranges. An empty range map
    carries :empty_diff.

- id: mutagen.git_diff.r2
  priority: must
  statement: |
    changed_lines/2 keys ranges by the exact repository-relative destination
    path and maps each selected rename destination to its source path, including
    pure renames. Whitespace and non-ASCII bytes in Git paths are preserved.
    Absolute paths and paths with a parent traversal segment are rejected.

- id: mutagen.git_diff.r3
  priority: must
  statement: |
    Refs outside the allowlist or containing two consecutive dots return
    :invalid_since_ref before any command runs. The first use of a caller ref
    verifies it as a commit after --end-of-options. Only full hexadecimal object
    IDs can be used as resolved revisions. The runner receives an executable
    and separate arguments, with roots and paths treated literally.

- id: mutagen.git_diff.r4
  priority: must
  statement: |
    Reading the diff and base blobs leaves the repository unchanged. Git
    configuration cannot run external diff, textconv, clean filters, fsmonitor
    hooks, or pagers during these reads. Color and configured patch prefixes
    do not affect the result. Missing history never triggers a fetch.

- id: mutagen.git_diff.r5
  priority: must
  statement: |
    An unavailable repository, Git executable, ref, merge-base, or malformed
    command result produces a structured :diff_unavailable error. Shallow
    history produces an error with shallow: true and a fixed fetch-depth hint.
    Output past the byte cap or a diff beyond the file cap produces a structured
    limit error without returning a partial map.

- id: mutagen.git_diff.r6
  priority: must
  statement: |
    base_file/3 reads the raw blob at a validated full merge-base ID and a
    literal path inside the configured roots. A missing tree entry yields
    :absent. Failed lookups and invalid inputs yield structured errors. A
    caller can use the old path of a rename to read the original base blob.
```

```spec-verification
- kind: tagged_tests
  target: test/mutagen_ex/git_diff_test.exs
  covers:
    - mutagen.git_diff.r1
    - mutagen.git_diff.r2
    - mutagen.git_diff.r3
    - mutagen.git_diff.r5
    - mutagen.git_diff.r6
- kind: tagged_tests
  target: test/integration/git_diff_test.exs
  covers:
    - mutagen.git_diff.r1
    - mutagen.git_diff.r2
    - mutagen.git_diff.r4
    - mutagen.git_diff.r6
```
