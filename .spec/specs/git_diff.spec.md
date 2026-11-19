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
  - mutagen.decision.git_diff_raw_worktree
  - mutagen.decision.git_diff_directory_scope
  - mutagen.decision.git_diff_tracked_scope
```

```spec-requirements
- id: mutagen.git_diff.r1
  priority: must
  statement: |
    changed_lines/2 returns the merge-base and HEAD commit IDs and inclusive
    new-side ranges from zero-context hunks in the working-tree diff. Only
    added, modified, or renamed regular .ex files inside the configured roots
    contribute ranges. The default root is lib. Git compares source as text,
    including files containing NUL bytes. Deletion-only hunks, mode-only
    changes, timestamp-only changes, and untracked files contribute no ranges.
    Intent-to-add files can contribute ranges. Changed symlinks, gitlinks,
    type changes, and entries Git can only describe as binary are listed in
    skipped with a reason. Every index symlink or gitlink at or under a root
    is listed as preexisting even without a source extension and even when
    unchanged. A changed entry can also carry its diff reason. Only a result
    with no ranges or skipped entries carries :empty_diff. A rename into
    scope from outside it is an addition. Every range ends within the working
    file's line count.

- id: mutagen.git_diff.r2
  priority: must
  statement: |
    changed_lines/2 keys ranges by the exact project-relative destination
    path and maps each selected rename destination to its source path, including
    pure renames. Whitespace and non-ASCII bytes in Git paths are preserved.
    Absolute paths and paths with a parent traversal segment are rejected.
    Roots and base-file paths are relative to the resolved working directory.
    The reader requires a Git working tree outside a submodule. Each component
    of a configured diff root must be a real directory without a .git entry.
    Invalid components report their path and type. An unchanged symlinked
    root and a root that changes during the diff have distinct causes.
    Matching normalizes tracked paths and roots to NFC. It also folds case
    when core.ignorecase is true or a case-flipped root is the same disk
    directory. Results retain the tracked spelling. The gate must use those
    keys as returned and treat a non-empty skipped list as incomplete.

- id: mutagen.git_diff.r3
  priority: must
  statement: |
    Refs outside the allowlist or containing two consecutive dots return
    :invalid_since_ref before any command runs. The allowlist accepts branch,
    tag, and remote-tracking names, full SHAs, and HEAD ancestry expressions.
    Git ref names that resolve ambiguously return an error with a full-ref hint.
    The first use of a caller ref
    verifies it as a commit after --end-of-options. Only full hexadecimal object
    IDs can be used as resolved revisions. The runner receives an executable
    and separate arguments, with roots and paths treated literally.

- id: mutagen.git_diff.r4
  priority: must
  statement: |
    Reading the diff and base blobs leaves the repository unchanged. Git
    configuration cannot run external diff, textconv, clean filters, fsmonitor
    hooks, or pagers during these reads. Color and configured patch prefixes
    do not affect the result. Inherited Git overrides, grafts, replace refs,
    and configured worktree redirects cannot change the selected history or
    working directory. Missing history never triggers a fetch.

- id: mutagen.git_diff.r5
  priority: must
  statement: |
    An unavailable repository, Git executable, ref, merge-base, or malformed
    command result produces a structured :diff_unavailable error. Shallow
    history produces an error with shallow: true and a fixed fetch-depth hint.
    Output past the byte cap or a diff beyond the file cap produces a structured
    limit error without returning a partial map. Paths outside the roots
    consume neither the diff byte budget nor the file cap. Missing working directories,
    unsupported Git versions, and promisor repositories have distinct causes.

- id: mutagen.git_diff.r6
  priority: must
  statement: |
    base_file/3 reads the raw blob at a validated full merge-base ID and a
    literal regular-file path inside the configured roots. A missing tree entry yields
    :absent. Failed lookups and invalid inputs yield structured errors. A
    caller can use the old path of a rename to read the original base blob.
    A symlink entry, the zero object ID, and a base ID that names an object
    other than a commit have distinct error causes.

- id: mutagen.git_diff.r7
  priority: must
  statement: |
    Git reads attributes from the empty tree. In-tree attributes cannot hide
    source or shift its changed ranges. A non-empty or non-regular repository
    info/attributes entry produces a distinct error before the diff runs.

- id: mutagen.git_diff.r8
  priority: must
  statement: |
    Git enforces ownership checks using the standard global safe.directory
    configuration. Dubious ownership has a distinct cause and a hint with the
    resolved checkout and the command to authorize it explicitly.
    Every Git call has a configurable deadline, defaulting to 30 seconds.
    A timeout attempts to terminate the Git process group and returns :timeout
    as its cause even if the signal cannot be sent. In that case the details
    say the child may still run. Paths in hints and details omit control
    characters.
    Git diagnostics are captured and are absent from the tool's stderr and
    returned error details.
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
    - mutagen.git_diff.r3
    - mutagen.git_diff.r4
    - mutagen.git_diff.r6
    - mutagen.git_diff.r7
    - mutagen.git_diff.r8
```
