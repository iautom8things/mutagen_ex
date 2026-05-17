---
id: mutagen.decision.preamble_in_run1_only
status: accepted
date: 2026-05-17
affects:
  - mutagen.cli
---

# Mix-task runtime preamble lives in `run/1` only, not `run/2`

## Context

`Mix.Tasks.Mutagen` exposes two arities:

- `run/1` — the production entry; calls `default_dispatch/0` then delegates
  to `run/2`. This is what `mix mutagen` invokes from the shell.
- `run/2` — the documented test seam; accepts a partial dispatch map,
  threads it through the pipeline, returns observable results without
  `System.halt/1`.

To unblock downstream adoption (`mutagen.cli.r14`), `mix mutagen` must
ensure four things before any phase runs:

1. The host project's compiled BEAMs are loaded (`Mix.Task.run("loadpaths")`
   then `Mix.Task.run("compile")`).
2. The `:ex_unit` application is started (so cited test files can `use
   ExUnit.Case` without raising).
3. The `:mutagen_ex` application is started (so `MutagenEx.TaskSup` is
   alive for `MutationLoop`).

The question: where does this preamble live — in `run/1` only, or in
`run/2` (idempotent so library callers benefit)?

## Decision

**The preamble lives in `run/1` only**, before delegating to `run/2`.
`run/2` stays preamble-free.

## Consequences

### Positive

- The existing test suite (which drives the Mix task via `run/2` from
  inside an already-running `mix test` invocation) is unaffected. `mix
  test` has already called `Mix.Task.run("compile")` for its own VM;
  invoking it again from inside a child phase would re-trigger
  compilation hooks and risks fighting ExUnit ordering.
- `run/2` remains a clean unit-testable seam — the entire
  cli/parse → orchestrator state machine can be exercised without
  application boot side effects.
- The split mirrors the existing convention: `run/1` is the
  side-effecting CLI; `run/2` is the pure pipeline.

### Negative

- Library callers using `MutagenEx.MutationRunner.run/1` directly (the
  documented library entry per README) do NOT get the preamble. They
  must ensure `:mutagen_ex` is started themselves. This is documented
  in the README's "Library entry" paragraph (a one-sentence touch-up
  ships with the implementation).
- A future maintainer might add a third entry path (e.g. a
  `MutagenEx.MutationRunner.run/2` taking a custom dispatch) that
  inherits neither the CLI preamble nor the test-seam exemption. The
  spec requirement (`r14`) names `run/1` explicitly; any new entry
  must re-evaluate.

### Alternative considered

**Idempotent calls in `run/2`** — `Application.ensure_all_started/1` is
naturally idempotent; `ExUnit.start/0` is too once started;
`Mix.Task.run/1` is a no-op when the task has run. Library callers
would benefit. Rejected because:

- The risk it mitigates (library-caller convenience) is moot: the
  documented library entry is `MutagenEx.MutationRunner.run/1`, NOT
  `Mix.Tasks.Mutagen.run/2`. The Mix task's `run/2` is explicitly a
  test seam.
- The risk it introduces (preamble side effects firing inside the test
  suite's already-prepared environment) is real and would erode the
  test-seam contract.

The clean split wins.
