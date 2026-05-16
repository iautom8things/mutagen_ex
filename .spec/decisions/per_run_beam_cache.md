---
id: mutagen.decision.per_run_beam_cache
status: accepted
date: 2026-05-15
affects:
  - mutagen.mutation_pipeline
---

# BeamCache as per-run ETS via cfg (not a supervised GenServer)

## Context

`mutagen-wrd.25` replaces the per-site `Code.compile_quoted/2` restore with a
binary swap via `:code.load_binary/3`. To do that, `MutagenEx` must snapshot
each module's original `.beam` before the first mutation and restore from
the snapshot after each site.

The initial architecture proposed a `MutagenEx.BeamCache` GenServer
registered as a child of `MutagenEx.Supervisor`, owning an ETS table whose
lifetime spans the whole VM session. Both the technical red-team
([04a-technical-challenges.md, finding #2]) and the scope auditor
([04c-scope-audit.md]) independently rejected this:

- **Cross-invocation staleness.** A snapshot taken during one `MutagenEx.run/2`
  call lingers across recompilations of the underlying app code. If a
  developer iterates in `iex -S mix`, runs mutations, edits source, then
  re-runs, the second run restores stale binaries — silently undoing the
  developer's edits in the BEAM.
- **Supervision shape.** `.18` deliberately limited `MutagenEx.Application`'s
  supervisor to one child (the named `Task.Supervisor`) per
  mutagen.decision.supervision_tree. Adding a second long-lived child
  expands the contract for marginal benefit — the GenServer holds no logical
  state beyond the ETS handle.
- **Testability.** Singleton state across tests forces explicit teardown
  in every test that touches `BeamCache`. Per-run state passed in via `cfg`
  has the same teardown semantics as any other test fixture (zero work).

## Decision

`MutagenEx.BeamCache` is a stateless module that operates on an ETS table
passed in via `cfg.beam_cache_table`. The table is created at the start of
`MutationRunner.run/1` and deleted in the `after` clause. No GenServer, no
supervisor child.

- Table creation: `:ets.new(:beam_cache, [:set, :public, read_concurrency: true])`
- Owner: the `MutationRunner.run/1` process; under `async_stream_nolink`,
  worker tasks insert and read via the table reference (`:public` access).
- API:
  - `BeamCache.snapshot(table, module, code_server)` — idempotent; reads
    the module's current `.beam` via `code_server.get_object_code(module)`
    and inserts `{module, beam_filename, binary}` into the table via
    `:ets.insert_new/2`. If the entry already exists, returns it unchanged.
  - `BeamCache.restore(table, module, code_server)` — looks up the entry
    and calls `code_server.load_binary(module, beam_filename, binary)`.
    Asserts the entry exists (the snapshot pre-pass must have populated it).
- First-touch serialization: snapshots happen in a serial pre-pass inside
  `MutationRunner.run/1` BEFORE `async_stream_nolink/4` dispatch. This
  closes the TOCTOU window technical red-team finding #1 raised: under
  parallelism, two workers can't race to snapshot the same module because
  no worker mutates anything until the pre-pass has finished.
- The `code_server` indirection is the new
  `MutagenEx.Test.CodeServer` behaviour facade (see
  mutagen.decision.code_server_facade). Production delegates to `:code`;
  tests inject a stub.

## Consequences

**Positive:**
- Supervision tree shape unchanged — `.18` contract honored.
- Cross-invocation staleness impossible: the table dies with the run.
- Testability: each test gets its own ETS table, no global teardown.
- TOCTOU race closed by the serial pre-pass + ETS `insert_new/2` semantics.

**Negative:**
- The ETS table must be threaded through every function that needs to
  snapshot or restore. `cfg` carries it; this widens the `cfg` map's
  surface by one field. (Same pattern as the existing `cfg.compiler`
  facade seam — no new convention introduced.)
- A run-aborted-without-cleanup path (e.g., `kill -9`) leaves the ETS
  table orphan only for the lifetime of the BEAM session — not a real
  concern for a one-shot Mix task; for `iex` callers, the next run
  creates a fresh table and the orphan is GC'd when the owning process
  exits.

## Related

- mutagen.decision.supervision_tree — the `.18` decision this preserves.
- mutagen.decision.code_server_facade — the testability seam.
