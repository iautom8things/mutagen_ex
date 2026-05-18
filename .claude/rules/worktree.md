<!-- agentic-worktree: module=host-elixir version=0.2.8 -->

---
description: Worktree-first workflow for host-run Elixir projects.
---

## Mandate

All implementation work happens in a linked git worktree. The primary checkout
tracks `main` and is reference-only for normal feature work.

## Create Worktrees

From the checkout that should act as the base:

```sh
make worktree-new BRANCH=feature/my-feature
```

The new branch is created from the current checkout's `HEAD`. This matters when
creating stage worktrees from a long-lived epic branch.

## Readiness Gate

Before implementation, run:

```sh
make smoke
```

For this profile, smoke verifies:

- `mix compile --warnings-as-errors`
- `mix test --max-failures 1`

If smoke fails, run `make worktree-bootstrap`, repair the failure, and re-run
`make smoke` before changing product code.

## Admin Commands

- `make worktree-info` / `make wti` - show current worktree configuration.
- `make worktree-status` / `make wts` - list worktrees with git status.
- `make worktree-cleanup NAME=<name>` / `make wtc NAME=<name>` - remove one
  clean worktree whose branch is merged into `WORKTREE_CLEANUP_BASE`.
- `make worktree-cleanup-all` / `make wtca` - remove all clean worktrees merged
  into `WORKTREE_CLEANUP_BASE`.
- `make worktree-prune` - prune stale git worktree metadata.

Set `WORKTREE_CLEANUP_BASE=main` when cleaning up after a PR lands. Leave the
default `HEAD` when cleaning a stage worktree after merging it into an epic
worktree.
