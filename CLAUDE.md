# mutagen_ex

<!-- agentic.rules:start -->
## Rules

Claude loads `.claude/rules/` natively. Codex reads this file and gets command- and file-gated rules from the PreToolUse hook. Always-on rules, for agents without a native loader:

- Read a ticket with `bw show <id>` or pick one with `bw ready`. Run `bw prime` only when the task needs the whole board (in-flight work across tickets, repo hygiene warnings): it prints about 5k tokens, which a session working one ticket should not pay. (`.claude/rules/beadwork.md`)
- All implementation work happens in a linked git worktree. The primary checkout tracks `main` and is reference-only for normal feature work. (`.claude/rules/worktree.md`)

Reference rules, read on demand:

`.claude/rules/`

| Rule | Covers |
| --- | --- |
| `worktree.md` | Worktree-first workflow for host-run Elixir projects. |

`.claude/scripts/rules-check --list` lists every rule.
<!-- agentic.rules:end -->

