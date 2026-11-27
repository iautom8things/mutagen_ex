<!-- agent-rules: generated v0.29.5 -->
# Agent Rules

This repo uses the portable agent-rules package.

Grok currently does not receive hook `additionalContext`, so dynamic rules are not injected into model context.
When a command or file path appears to match one of these rules, read the listed file before acting.

| Rule | Source | Covers |
| --- | --- | --- |
| `ancora` | `.claude/rules/ancora.md` | Repo-resident behavioral specs and verification cadence for Ancora and SpecLedEx. Specs are the source of truth for what must be true. |
| `beadwork` | `.claude/rules/beadwork.md` | Work tracking with bw (beadwork). Persists plans, progress, and decisions to git across sessions. |
| `testing` | `.claude/rules/testing.md` | ExUnit test patterns. Test cases, Mox, Oban, process lifecycle, LiveView assertions. |
| `worktree` | `.claude/rules/worktree.md` | Worktree-first workflow for host-run Elixir projects. |
| `beadwork-filing` | `.claude/dynamic-rules/beadwork-filing.md` | Before a bw create, search for a duplicate and pick one of three outcomes; only /jira-sync writes Jira. |
| `elixir-flaky-tests` | `.claude/dynamic-rules/elixir-flaky-tests.md` | ExUnit flake prevention when writing tests. Mailbox ordering, deadlines, and failure symptoms. |
| `elixir-patterns` | `.claude/dynamic-rules/elixir-patterns.md` | Elixir house conventions. Timeouts, behaviour impls, doc interpolation, block rebinding, struct access, concurrency. |
| `worktree-cleanup` | `.claude/dynamic-rules/worktree-cleanup.md` | Hard gate — raw `git worktree remove` / `git worktree prune` are blocked; use `make worktree-cleanup` / `make worktree-prune`, or `scripts/lane rm` for a /speedy-epic lane. |
