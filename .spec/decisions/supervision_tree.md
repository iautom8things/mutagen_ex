---
id: mutagen.decision.supervision_tree
status: accepted
date: 2026-05-14
affects:
  - mutagen.mutation_pipeline
  - mutagen.coverage
---

# Application + named Task.Supervisor + singleton-ownership contract

## Context

Four findings from the post-`.16` review converged on this decision:

- **F2-arch — orphaned grandchildren on `Task.shutdown(:brutal_kill)`.**
  `Task.async` + `Task.shutdown(task, :brutal_kill)` kills only the direct
  task pid. Grandchildren spawned by killed tests (Phoenix.PubSub trees,
  Ecto connection pools, etc.) survive as orphans linked to a now-dead pid.
  The supervisor's child-table also lags behind the death until its own
  monitor fires asynchronously. Across N timeout sites the runner accumulates
  orphan trees that subsequent sites observe through the r7 snapshot machinery.
- **F25 — no library entrypoint.** With `lib/mutagen_ex.ex` deleted in `.17`,
  there is no `MutagenEx.Application` and no `mod:` declaration in `mix.exs`.
  Library callers depending on `:mutagen_ex` do not get a supervision tree on
  application start; only the `mix mutagen` CLI route works.
- **F26 — undocumented singleton ownership.** `:cover_server` and
  `ExUnit.Server` are BEAM-global named processes. Two concurrent
  `MutagenEx.CoverageRunner.run/1` callers silently corrupt each other's
  state. The existing r1 rejection at `coverage_runner.ex:96-106` checks for
  `:cover_server` registration but neither names an owner nor explains why
  the rejection exists.
- **F46 (partial, from `.13`) — brutal-kill leaves linked processes / sockets
  / ETS.** The `.13` snapshot machinery detects growth but never reaps. With a
  supervisor in place, `terminate_child/2` propagates `:shutdown` recursively
  through the link tree, which reaps the common-case fixtures (untrapped
  linked processes, OTP-supervised subtrees) — but not hand-rolled trap-exit'd
  GenServers that swallow `:EXIT` info messages.

The tension this decision resolves: how much supervision posture do we adopt
in `.18`, given that `.17` has landed `with_restore/4` and that `.30`
(parallelism) is the actual consumer of more sophisticated supervision? The
answer below picks the minimum that closes F2-arch / F25 / F26 cleanly while
leaving F46 honestly partial and parallelism untouched.

## Decision

- **Add `MutagenEx.Application`.** A one-for-one supervisor whose only child
  (initially) is a named `Task.Supervisor` registered as `MutagenEx.TaskSup`.
  The root supervisor is itself named `MutagenEx.Supervisor` so introspection
  via `Process.whereis/1` is straightforward.
- **Declare `mod: {MutagenEx.Application, []}` in `mix.exs`.** The supervisor
  starts whenever the `:mutagen_ex` application boots — both for the `mix
  mutagen` CLI path (which already starts the application as a side effect of
  the Mix task) and for library callers depending on `:mutagen_ex`. F25 is
  structurally satisfied by this declaration; library callers do not need a
  new public-API surface to get the supervision tree.
- **Swap `MutationLoop`'s per-site task to `Task.Supervisor.async_nolink`.**
  Replace `Task.async(fn -> ... end)` with
  `Task.Supervisor.async_nolink(MutagenEx.TaskSup, fn -> ... end)`. The
  caller is no longer linked to the task; communication remains via the
  `Task` struct's monitor reference. `Task.yield/2` still works because it
  speaks monitor, not link.
- **Swap brutal cancellation to `Task.Supervisor.terminate_child/2`.** The
  two-phase cancellation contract from `mutagen.decision.timeout_handling`
  stays: phase 1 keeps `Task.shutdown(task, cancel_grace_ms)` for its
  structured-return shape (`{:ok, value}` if the task finished during the
  grace window). Phase 2 swaps from `Task.shutdown(task, :brutal_kill)` to
  `Task.Supervisor.terminate_child(MutagenEx.TaskSup, task.pid)`, then calls
  `Process.demonitor(task.ref, [:flush])` to prevent stale `:DOWN` messages
  accumulating in the runner's mailbox across timeout sites.
- **Document `MutagenEx.TaskSup` as singleton owner.** Extend the existing
  `coverage_runner.ex` r1 rejection at L96-106 — the message now names
  `MutagenEx.TaskSup` as the documented owner of `:cover_server` and
  `ExUnit.Server` during a MutagenEx mutation cycle, and points readers at
  this decision file. No new helper function (no `ex_unit_in_progress?/0`).
- **What is NOT changed in `.18`:**
  - The outcome-tuple shape from `MutationLoop.run/1` is frozen
    (`{:ok, _, _}` / `{:timeout, _}` / `{:error, _, _}` etc. retain identical
    shapes; tests continue to pattern-match successfully).
  - `MutationRunner.run/1` internals — `.17`'s `with_restore/4` is the right
    wrapping shape and is not duplicated or refactored.
  - `Mix.Tasks.Mutagen` — the CLI path continues to work unchanged; the
    Application starts as a side effect.
  - `:code.purge/1` post-timeout settle from `.13` — retained on top of the
    new supervision swap.

## Rationale (alternatives considered)

- **Inline supervisor (no application callback).** Would have required every
  CLI invocation to start a per-run supervisor and tear it down. Loses
  F25 (library callers still have no entrypoint) and adds boot/teardown cost
  on every `mix mutagen` invocation. Rejected.
- **`DynamicSupervisor`.** Equivalent topology for our use case
  (per-site one-shot children) but requires manual child-spec authoring per
  start_child call. `Task.Supervisor` is the purpose-built wrapper for
  `Task.async`-shaped work and gives us `async_nolink` + `terminate_child`
  off-the-shelf. Rejected.
- **Out-of-process workers via Port or `Node.spawn`.** Genuine isolation —
  killed worker can never orphan local BEAM state. But: (a) significantly
  larger diff than the ticket scope, (b) cross-process communication adds a
  serialization seam to the per-site outcome path that today is just a
  function return, (c) the landing-plan spec captured this as a v2
  Won't-Have. Captured below in §Won't-Have.
- **Threaded-pid supervisor (caller-owned `Task.Supervisor` per-run).** Would
  satisfy the per-call ownership story more cleanly but loses F25 and adds
  caller boilerplate. Rejected for the same reason as inline.

## Named registration

`MutagenEx.TaskSup` is registered by name rather than passed by pid for
three reasons:

1. Test injection: the `MutationLoop` `input` typespec now accepts an
   optional `:task_sup` key (defaulting to `MutagenEx.TaskSup`). Tests can
   inject a per-test `Task.Supervisor` pid for isolation. Production reads
   the default name.
2. Introspection: `Process.whereis(MutagenEx.TaskSup)` from `iex -S mix` is
   the smoke test for "Application booted correctly."
3. Decision file references can name a stable symbol (`MutagenEx.TaskSup`)
   rather than referring to an opaque pid in prose.

## Cancellation latency budget

- `cancel_grace_ms`: 100 ms default (unchanged from `.13`).
- `Task.Supervisor` `:shutdown_timeout`: 5_000 ms default (accepted from
  OTP). This bounds only a hypothetical scenario in which the per-site task
  itself traps `:shutdown` — which it does not, because `Task` does not call
  `Process.flag(:trap_exit, true)` (verified at `task/supervised.ex:69-74`).
  In practice the task dies on the `:shutdown` signal in microseconds; the
  5_000 ms is moot.
- Grandchild teardown is asynchronous BEAM signal propagation that fires
  after `terminate_child/2` has already returned. The user-visible latency
  per timeout-classified site is dominated by the 100 ms grace window plus
  sub-millisecond supervisor bookkeeping. Earlier architecture drafts cited
  a "5_100 ms worst case" — that number is wrong on top of being repetitive
  and is replaced wherever it appeared (CHANGELOG, README).
- The cooperative grace window rarely fires as "successful cooperative
  completion" for cover-recompile workloads; it serves as the mailbox-drain
  window for tasks that finished just before the yield timed out. Deeper
  tuning is `.30` territory.

## Singleton-ownership contract

While a MutagenEx mutation cycle is in flight (defined operationally as
`MutagenEx.MutationRunner.run/1` or `Mix.Tasks.Mutagen.run/1` having entered
its task body), `MutagenEx.TaskSup` is the documented owner of two
BEAM-global named processes:

- `:cover_server` — registered when `:cover.start/0` completes during the
  coverage phase. Released when `:cover.stop/0` runs in the runner's
  `on_exit/1` (or `try/rescue` cleanup).
- `ExUnit.Server` — registered when ExUnit is loaded (which the Mix
  environment does before the task even starts). Concurrent `ExUnit.run/1`
  calls collide on its internal state regardless of `:cover` involvement.

The rejection mechanism for a concurrent second caller is unchanged:
`Process.whereis(:cover_server) != nil` at the entry of
`CoverageRunner.run/1` triggers `{:error, :cover_already_running, %{message:
_}}`. The message is enriched in `.18` to name `MutagenEx.TaskSup` and
reference this decision file.

**Known unguarded window.** The check happens before `:cover.start/0`. Two
callers entering between each other's check and start collide on
`:cover.start/0` and fall back to the existing
`{:error, {:already_started, _pid}} -> :ok` path. This race is multi-second
wide (the entire coverage phase runs before any TaskSup task is spawned), so
a `TaskSup.children/1`-based check would not close it either. The
`coverage_runner.ex` r1 prose is honest about this. Closing the window
requires a GenServer arbiter and becomes mandatory when `.30` adds
parallelism; `.18` ships without it.

## Relationship to predecessors (.13, .17)

- **`.13` (`:code.purge` settle pass).** The settle pass operates on
  Code.Server state, not the task link tree. It remains on top of the
  supervision swap: post-`:timeout` outcome, the runner calls `:code.purge/1`
  on the site's scoped modules before restore. Orthogonal layers; both
  retained.
- **`.17` (`with_restore/4`).** Wraps the protected-mutation window so a
  raise/throw/exit inside the loaded-mutation span triggers restore before
  the exception re-propagates. Independent of the supervision swap. The
  per-site task crashing inside the task body funnels through `Task.yield/2`
  / `Task.shutdown/2`'s monitor handling and arrives at the `mutation_loop`
  case arm as `{:exit, reason}` — it does NOT raise into `with_restore`'s
  rescue. The c1/c2 integration tests continue to gate this invariant.

## Won't-Have (v2 design notes)

- **Out-of-process workers via Port or `Node.spawn`.** True isolation;
  killed worker cannot orphan local BEAM state. Out of scope for `.18`
  because: (a) the ticket explicitly forbids it; (b) the v1 supervision
  swap closes F2-arch for the realistic test-fixture grandchild classes
  (untrapped links + OTP-supervised subtrees); (c) parallelism (`.30`) is
  the natural place where out-of-process semantics become valuable.
- **GenServer arbiter for the `:cover.start/0` race.** Closes the
  unguarded window in the singleton-ownership contract. Mandatory in `.30`
  once parallelism is on the table; defensible to defer in `.18` because
  the contract today is "one concurrent run per BEAM" and concurrent
  invocations from user shells are vanishingly rare in practice.
- **Per-call (caller-owned) `Task.Supervisor`.** Useful if `mutagen_ex`
  ever needs to support multiple concurrent runs in the same BEAM; out of
  scope for v1.

## Consequences

**Positive**:

- F2-arch closure for the common grandchild classes (untrapped linked
  processes, OTP-supervised subtrees). Killed mutations no longer accumulate
  orphan trees across sites; r7 snapshot delta should converge to zero on
  `:timeout` outcomes whose only side effect is class-(a) or class-(b)
  descendants.
- F25 closure: library callers depending on `:mutagen_ex` get the
  supervision tree automatically on application start. No new public-API
  surface required.
- F26 closure: `:cover_server` and `ExUnit.Server` have a named owner with
  a documented contract; concurrent callers are refused with a structured
  error that names the owner and points at this decision file.
- Supervisor child-table bookkeeping stays consistent under
  `terminate_child/2` (synchronous removal of the dead child) — minor but
  real benefit over `Task.shutdown(:brutal_kill)`'s lazy reap-on-monitor.
- Foundation for `.30` (parallelism): the named supervisor is already in
  place; `.30` adds concurrency over it without re-architecting.

**Negative**:

- F46 closure is partial, not complete. Hand-rolled trap-exit'd GenServers
  that swallow `{:EXIT, _, :shutdown}` info messages survive both the `.13`
  brutal path and the `.18` supervised path. The snapshot-delta machinery
  remains advisory for this class.
- `mod: {MutagenEx.Application, []}` fires on every `mix test` of a project
  that depends on `:mutagen_ex`, including in test environments. Tests that
  pattern-match on supervisor absence will break. The README's
  "Installation" section recommends `only: [:dev, :test]` scoping in
  dep'ing projects' `mix.exs`.
- The singleton-ownership contract is honest about its multi-second
  unguarded window. Concurrent callers from separate user shells in the same
  BEAM (e.g. someone running `mix mutagen` twice in `iex`) may collide on
  `:cover.start/0`. The fallback `{:error, {:already_started, _pid}} -> :ok`
  path means this is not a crash, but the second caller's results may be
  contaminated. v2 arbiter closes this.
- One new module (`MutagenEx.Application`) and one new test file
  (`test/mutagen_ex/supervision_test.exs`) join the maintenance surface.
