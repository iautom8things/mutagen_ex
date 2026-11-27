---
# agent-rules: generated v0.29.5 sha256=4221f4cbf5746cc19fe5c9568e36d757d0a7479d4405b92a1fb2693d62533d80
description: Repo-resident behavioral specs and verification cadence for Ancora and SpecLedEx. Specs are the source of truth for what must be true.
# Deliberately NOT write_only: specs-as-source-of-truth must be in context when
# reading and planning, not only when editing.
paths:
  - ".spec/**"
  - "lib/**/*.ex"
  - "test/**/*.exs"
---

## Start with the relevant subjects

Read `.spec/AGENTS.md`, then read only the subjects named by `make spec-next`
(`mix spec.next` in a host-run repo or a lane) or the task's `Advances:` field.
Each subject lives at `.spec/specs/<subject>.spec.md`.

## Verification cadence

### SpecLedEx

When the dependency in `mix.exs` is `:spec_led_ex`, use `make spec-check`.
If you run Mix directly in the repo's configured environment,
`mix spec.check --no-run-commands` keeps the gate structural. Bare
`mix spec.check` runs verification commands by default.

### Ancora

Ancora has two commands and no execution rung. In a compose worktree, run them
through make; in a host-run repo or a lane, run the bare `mix` form:

- `make spec-validate` / `mix spec.validate` checks corpus structure and repo-state
  findings. Use it during implementation.
- `make spec-check` / `mix spec.check` adds diff-scoped analysis against a base.
  Run it before closing work and in CI.

Neither command runs project tests or verification commands. Run the repo's
own compile and test commands separately.

The verdict is the last stdout line: `spec.check result=…`. A non-zero exit with no verdict line means the run crashed before the gate finished — treat it as failure.

## Ancora finding vocabulary

Every finding has one of four severity levels: `error`, `warning`, `info`, or
`off`. `spec.check` fails on errors and warnings. `spec.validate` fails on
errors, and `--strict` makes warnings fail too. Info findings print with
`--verbose` or `ANCORA_SHOW_INFO=1`. Off findings do not print.

The closed registry is grouped by family:

| Family | Codes |
|---|---|
| `derived` | `derived/drift`, `derived/growth`, `derived/shrink`, `derived/unresolved_calls`, `derived/unparseable_source`, `derived/unanchored_subject` |
| `change` | `change/uncovered_file`, `change/missing_decision` |
| `tags` | `tags/new_requirement_untagged`, `tags/parse_error`, `tags/dynamic_value`, `tags/requirement_untagged`, `tags/unknown_requirement` |
| `append` | `append/requirement_deleted`, `append/must_downgraded` |
| `format` | `format/retired_construct` |
| `spec` | `spec/parse_error`, `spec/duplicate_id`, `spec/invalid_id`, `spec/missing_field`, `spec/unknown_reference`, `spec/requirement_unverified` |
| `adr` | `adr/parse_error`, `adr/missing_section`, `adr/affects_empty`, `adr/affects_unresolved` |
| `overlap` | `overlap/duplicate_covers`, `overlap/must_stem_collision` |
| `config` | `config/unknown_key`, `config/invalid_value` |

Fix the condition named by the finding. In particular, drift, growth, and
shrink clear only when the same diff makes a substantive edit to the affected
subject's requirement or scenario blocks. Restore the code or test instead
when the contract did not change.

## Acknowledge a mechanical Ancora edit

Use a trailer only for a mass mechanical edit whose diff does not change the
contract:

```text
Spec-Ack: <code>=<info|warning>
```

The trailer accepts explicit finding codes, has no presets, and only lowers a
severity to `info` or `warning`. It cannot turn a finding off. Normal behavior
changes need substantive requirement or scenario edits, not a trailer.

## Per-subject overrides in Ancora

Use a subject override for a standing constraint such as an integration-only
subject whose tagged tests cannot call production code directly. Each entry
needs the subject, code, severity, and a concrete reason:

```yaml
overrides:
  - subject: project.core
    code: derived/unanchored_subject
    severity: info
    reason: Covered by an external integration suite.
```

Do not disable a finding repo-wide to accommodate one subject.

## Ancora base selection

Without `--base`, Ancora uses `default_base` from `.spec/config.yml`, which
defaults to `origin/main`. If that ref is missing or cannot be resolved, use
one of the three remedies named by the gate:

1. Run `git fetch origin main` when the remote branch exists.
2. Pass `--base <ref>` for this run (`make spec-check BASE=<ref>` with the worktree
   module). Use `--base HEAD` for a new repo with no remote.
3. Set `default_base` in `.spec/config.yml` when the repo uses another trunk.

## Beadwork links

Use `bw list --all --grep "Advances: <subject.id>"` to find tasks for a
subject. The grep value is a literal substring.
