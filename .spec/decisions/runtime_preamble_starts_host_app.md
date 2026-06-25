---
id: mutagen.decision.runtime_preamble_starts_host_app
status: accepted
date: 2026-06-25
affects:
  - mutagen.cli
  - mutagen.mutation_pipeline
---

# The `run/1` runtime preamble starts the host OTP application

## Context

`mutagen.decision.preamble_in_run1_only` established that the `mix mutagen`
runtime preamble lives in `Mix.Tasks.Mutagen.run/1` only and, at the time,
ensured three things before any phase ran: host BEAMs loaded
(`loadpaths` + `compile`), `:ex_unit` started, and `:mutagen_ex` started
(so `MutagenEx.TaskSup` is alive for `MutationLoop`).

Two independent Phoenix/Ecto efficacy studies (atlas, builder) then found
the same adoption blocker: the preamble never starts the **consumer
project's own** OTP application. Cited tests that need `Repo`/Ecto Sandbox,
`Mox.Server`, `Phoenix.PubSub`, or any supervised GenServer abort at
baseline because the host supervision tree is not running. On builder this
left ~76% of the test surface unreachable to mutagen; atlas worked around
it with a hand-rolled `MutagenApp` shim. Structurally this is the same
shape as wrd.40: the runtime preamble assumed more host state than was
actually present.

This decision extends `preamble_in_run1_only` rather than reversing it:
the `run/1`-only placement and the `run/2` test-seam exemption are
unchanged. What changes is *what the `run/1` preamble does*.

## Decision

The `run/1` preamble adds a fourth step: it starts the host project's own
OTP application via `Mix.Task.run("app.start")`, after `compile` and
before `Application.ensure_all_started(:mutagen_ex)`.

- Because `app.start` clears the Mix archive code path, the preamble
  re-appends it with `Mix.Local.append_archives/0` immediately after, so
  archive-installed runs (`mutagen.cli.r16`) keep finding `:mutagen_ex`
  on the code path.
- A `--no-host-app` flag and a `MUTAGEN_NO_HOST_APP` env var
  (`1`/`true`/`yes`) opt out, for libraries and self-test sandboxes that
  intentionally want a minimal boot — notably the mutagen_ex self-mutation
  Lab, which must keep working without a host app.

The authoritative behavioral contract lives in `mutagen.cli.r14` (default
host-app start + opt-out) and `mutagen.cli.r16` (archive-install mode).

## Consequences

### Positive

- Phoenix/Ecto/Mox/PubSub test surfaces become reachable to mutagen
  without per-project shims.
- The opt-out keeps the dependency-free minimal-boot path intact for the
  self-mutation Lab and library callers.

### Why this affects `mutagen.mutation_pipeline`

`mutagen.mutation_pipeline.r13` owns the supervision-tree-on-boot contract
(`MutagenEx.Application` → `MutagenEx.Supervisor` → `MutagenEx.TaskSup`).
Starting the host app means a *second*, host-owned supervision tree now
boots alongside mutagen_ex's during a CLI run. The mutation_pipeline's own
tree and its timeout-reaping classes (r14) are unchanged — host-owned
PubSub/Ecto-pool descendants were already covered by reaping class (b) —
but the boot sequence is now cross-cutting between the two subjects, which
is why this ADR lists both in `affects`.

### Negative

- An extra `app.start` lengthens preamble time on large host apps. This is
  one-time per `mix mutagen` invocation, not per mutation site.
- Host apps with side-effecting `Application.start/2` callbacks now run
  those side effects during a mutagen run. `--no-host-app` is the escape
  hatch when that is undesirable.
