---
# agent-rules: generated v0.29.5 sha256=148bf3afd0f5a4ab4107f735c6cbb127bc02f20e737ac844a80d6f52c0c9d806
description: Work tracking with bw (beadwork). Persists plans, progress, and decisions to git across sessions.
---

## Mandate

Read a ticket with `bw show <id>` or pick one with `bw ready`. Run `bw prime` only when the task needs the whole board (in-flight work across tickets, repo hygiene warnings): it prints about 5k tokens, which a session working one ticket should not pay.

Committing, closing issues, and syncing are part of completing a task — not separate actions requiring additional permission.

## Hook-enforced calling conventions

Fail-closed PreToolUse hooks enforce these four conventions. Prose alone was
not enough (~90 pipeline errors in 48h before the gates). Treat them as hard
constraints, not style notes:

1. **One bw write per Bash call.** Do not batch `bw comment`, `bw close`,
   `bw label`, or other write-side subcommands in the same shell command
   (`&&`, `;`, `|`, …). Post the comment alone, then run the rest. Chains
   make the body unisolatable and the attribution gate blocks them by name.
2. **Single-heredoc positional comment body.** `bw comment <id> <text>` —
   body is a positional argument only. Use one quoted heredoc:

   ```bash
   bw comment <id> "$(cat <<'EOF'
   IMPLEMENTED
   Session: …
   Log: …
   EOF
   )"
   ```

   Pinned bw 0.13.3 accepts `-a/--author` and `--json` on
   `bw comment`. Any other short flag (`-m`, `-F`, `-phase:…` intended for a
   later command, …) is **swallowed into the text positional** at exit 0 —
   the real body is discarded. Do not invent flags; do not chain a label or
   close onto the comment. The hook accepts file bodies only when the
   installed bw advertises `-F/--file`.
3. **`Advances:` is the first description line on create.** Every
   behavior-implementing `bw create` must put `Advances: <subject.id>[, …]`
   as the first line of the description. Pass it inline in single quotes or
   as a quoted heredoc (`-d "$(cat <<'EOF' … EOF)"`); never type `\n` in
   single quotes, bw stores it literally. The create-advances gate blocks
   headed creates that omit it.
4. **`bw update -t` sets type, not title.** `-t` / `--type` changes the issue
   type. Never use `-t` intending to set a title.

## Common Commands

- `bw prime` — current status of in-flight implementation work
- `bw list --all --grep "..."` — find tasks (e.g. by spec subject)
- `bw show <task>` — read a task's full description
- `bw close <task>` — close a task once verification passes
- `bw sync` — run it bare: `bw sync 2>&1 | tail -1` exits 0 when the sync
  failed, and the next `bw-url` links an unpushed ticket

For a text list with a positive `--limit`, read the `... and N more` footer
and raise the limit if you need those rows. For a complete JSON result, use
`--limit 0` to keep the current filters, or `--all` to include all statuses.

## Beadwork ↔ Ancora linking

Every beadwork task that implements behavior includes an `Advances:` field listing the Ancora subject IDs it advances:

```
Advances: <subject.id>[, <subject.id>...]
```

- To find tasks for a subject: `bw list --all --grep "Advances: <subject.id>"`
  (`--grep` is a literal substring match, not a regex)
- To find specs for a task: read the `Advances:` line, then open `.spec/specs/<subject>.spec.md`

See `ancora.md` for what to do with those subjects once you've found them.
