---
# agent-rules: generated v0.29.5 sha256=f32c59c09129915cea6bb3e8e181643871ce15c39a21ec1a1f984e5fdcfdab2e
description: Before a bw create, search for a duplicate and pick one of three outcomes; only /jira-sync writes Jira.
# The first `bw create` in each agent context is denied once with this rule;
# the unchanged retry passes. `bw list` is spared so the duplicate search the
# rule teaches is never refused, and `--help` / `-h` so reading usage does not
# spend the deny. `bw-plan` is a different argv[0], so the plan board is never
# gated.
deny_gate_command:
  - bw
deny_gate_args_all:
  - create
deny_gate_args_none:
  - list
  - --help
  - -h
deny: once
should_deny:
  - "bw create 'Fix the sync marker' -t task -d 'Advances: x.y'"
  - "bw -C ~/dev/cs/atlas create 'Atlas follow-up' --silent"
  - "cd /repo && bw create 'Chained create' -t bug"
  - "FOO=1 bw create 'Env-prefixed create'"
should_not_match:
  - "bw-plan create 'Plan board ticket'"
  - "bw create --help"
  - "bw create -h"
  - "bw list --all --grep create"
  - "bw list --all --grep 'bw create'"
  - "bw show adf-123 --json"
  - "bw comment adf-123 'next: bw create a follow-up'"
  - "git commit -m 'gate the first bw create per context'"
  - "rg -n 'bw create' llms/skills/"
---

## Filing work in bw

Before a `bw create`, search for a duplicate: `bw list --all --grep <words>`.
When a ticket matches, comment on it (`bw comment <id>`) instead of creating.
File findings about shared agent or spec tooling (skills, hooks, agent rules,
specs tooling) on the agentic-dotfiles board (adf), not the repo under review.

Each thing you want to track has one of three outcomes:

- **No ticket.** It fits the current task, it is a note on an existing ticket
  (`bw comment` there), or it has no evidence yet (session report or /ideate).
- **bw only (the default).** Anything an agent would pick up: tasks, stages,
  investigations, bugs with evidence, follow-ups, cut scope.
- **Rolls up to Jira.** Anything a PM plans around or asks about in a status
  meeting: an outcome a stakeholder notices, a milestone or date, a decision
  made outside engineering, an ask of a named person, a risk that moves a date.

The Jira outcome applies only when `bw config get jira.project` prints a key.
Exit 1 ("key not found") means the board is not linked: engineering work still
goes to bw, but asks of named people, messages, readouts and milestones get no
ticket. One Jira issue maps to one bw epic or a cluster of them, never a stage
or a task. Agents never write Jira. File the bw epic, or note it on the one
that exists. The next /jira-sync links it to an issue or proposes one.

If no ticket matches and the create is still right, re-run it unchanged.
