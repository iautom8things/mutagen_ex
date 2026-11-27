---
# agent-rules: generated v0.29.5 sha256=6f050a9b91c89db658db2da9dba76a292041f0d5a1d29279e66ec9f2304a3690
description: Hard gate — raw `git worktree remove` / `git worktree prune` are blocked; use `make worktree-cleanup` / `make worktree-prune`, or `scripts/lane rm` for a /speedy-epic lane.
# deny: always — the make targets are the only sanctioned teardown path; the
# hook only sees agent-issued commands, so make's internal git calls (and the
# lane script's own `git worktree remove`) are unaffected.
# Structured gate (token membership) closes the `git -C <path> worktree remove`
# argument-variation bypass that the old adjacency regex missed.
# deny_gate_args_none spares `prune --dry-run` / `prune -n`: it only reports.
# The last flag wins, as in git: a later `--no-dry-run` (or an abbreviation of
# it) cancels the exemption and the command is denied; a later `-n` or
# `--dry-run` restores it.
deny_gate_command:
  - git
deny_gate_args_all:
  - worktree
deny_gate_args_any:
  - remove
  - prune
deny_gate_args_none:
  - --dry-run
  - -n
deny: always
should_deny:
  - "git worktree remove ../foo"
  - "git -C /repo worktree prune"
  - "cd /y && git worktree remove z"
  - "command git worktree remove x"
  - "ls; git status; git worktree remove ../wt; echo done"
  - "if [ -d ../wt ]; then git worktree remove ../wt; fi"
  - "timeout 30 git worktree remove ../wt"
  - "nohup git worktree remove ../wt"
  - "git worktree prune -n --no-dry-run"
  - "git worktree prune --dry-run --no-dry-run"
  - "git worktree prune --dry-run --no-dry"
should_not_match:
  - "git -C /repo worktree prune --dry-run -v"
  - "git worktree prune -n"
  - "git worktree prune -n --verbose"
  - "git worktree prune --no-dry-run -n"
  - "git commit -m 'never run git worktree remove by hand'"
  - "rg -n 'git worktree remove|git worktree prune' docs/"
---

## Worktree teardown must go through `make`

You are about to run a raw `git worktree remove` or `git worktree prune`. Both
bypass `worktree-profile-before-cleanup` — the per-profile teardown step — and
both skip the refusal gates that protect the primary checkout and unmerged
work. What the teardown step does depends on the profile this repo installed:
on Compose profiles it brings the project down, removes volumes with its
Compose project label, and checks the exact `<project>_build` and
`<project>_deps` names for older seeds. Cleanup keeps the worktree if any
of those volumes survive. If Docker is unavailable, cleanup warns that
its resources stay for later review. Host profiles can skip Docker teardown.

Use the make targets instead:

```sh
# Single worktree, clean + merged
make worktree-cleanup NAME=<worktree-dir-name>

# Bypass dirty / unmerged refusal (still runs the cleanup hook)
make worktree-cleanup NAME=<worktree-dir-name> FORCE=1

# Worktree that lives outside WORKTREE_ROOT (scratch dir, /tmp, sibling tree)
make worktree-cleanup DIR=<absolute-path-to-worktree> FORCE=1

# Batch-cleanup everything merged into WORKTREE_CLEANUP_BASE
make worktree-cleanup-all
make worktree-cleanup-all FORCE=1
```

`NAME=` resolves under `WORKTREE_ROOT`; `DIR=` takes any path. A managed
worktree created somewhere else still needs the profile cleanup through
`DIR=`.

Raw teardown is exempt for standalone scratch repositories when both the
checkout and its Git metadata live under the scratchpad, `/tmp`, or `$TMPDIR`.
A linked checkout in scratch space still needs the managed cleanup when its
Git metadata lives outside scratch.

`FORCE=1` exists so you can clean up a worktree whose branch never landed (was
abandoned, was experimental, or already-merged-elsewhere) without having to
commit garbage just to satisfy the refusal gates. The primary-checkout refusal
is never bypassable.

For orphaned **administrative metadata** (the linked worktree directory was
deleted out-of-band and `.git/worktrees/` needs cleaning), use
`make worktree-prune` — same effect as raw `git worktree prune`, but through
the sanctioned path. `git worktree prune --dry-run` (or `-n`) only reports, so
it is allowed.

A /speedy-epic lane has no Compose stack; remove it with the skill's lane
script, `scripts/lane rm <epic> <lane>` (`<epic>` is the epic worktree path),
which also deletes the lane branch.

Raw `git worktree remove` and a real `git worktree prune` stay blocked for
managed repositories.
