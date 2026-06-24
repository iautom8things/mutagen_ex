---
id: mutagen.decision.parallel_experimental_gate
status: accepted
date: 2026-06-24
affects:
  - mutagen.mutation_pipeline
  - mutagen.cli
---

# Gate `--max-concurrency > 1` as experimental now; defer real isolation to CF2b

## Context

`MutationRunner.run/1` can dispatch per-site work through
`Task.Supervisor.async_stream_nolink/4` when `cfg.max_concurrency > 1`
(see [mutagen.mutation_pipeline](../specs/mutation_pipeline.spec.md) r15).
That parallel path is materially faster on large scopes, but the
in-process pipeline ([mutagen.decision.in_process_pipeline](in_process_pipeline.md))
shares three pieces of **process-global** BEAM state across every per-site
task:

- **ExUnit's server** — `ExUnit.Server` consumes a single global
  registered-modules list at each `ExUnit.run/0`. Two parallel
  `ExUnit.run/0` calls interleave that list, so a worker can run against
  the wrong module set.
- **The Code.Server's per-module load locks** — two parallel sites that
  mutate the SAME module collide on `Code.compile_quoted/2`; the loaded
  bytecode for a module is a single global slot, so one worker's mutant
  can be observed by another worker's test run.
- **`:cover` instrumentation state** — coverage counters are global and
  not partitioned per task, so concurrent runs corrupt each other's
  coverage attribution.

The net effect on a real ExUnit/`:cover` backend is **incorrect
kill/survive classification and corrupted coverage** — silent wrong
answers, the worst failure mode for a correctness tool. Two structural
shapes were on the table to make `> 1` honestly correct:

1. **Real in-VM isolation** — per-task ExUnit servers, isolated
   Code.Server instances, partitioned `:cover` state. This is not
   feasible without deep BEAM/Code.Server surgery: the Code.Server and
   `:cover` are singleton, node-global services.
2. **OS-process sharding** — fan the site set out across several child
   OS processes (each a fresh BEAM owning its own ExUnit server,
   Code.Server, and `:cover`), then merge the per-shard JSON. This is the
   only shape that actually removes the shared-global-state hazard, but
   it is a substantial build (process supervision, scope partitioning,
   result merge, failure semantics).

Neither lands in this change. CF1 (the outer-task restore sweep,
[r17](../specs/mutation_pipeline.spec.md)) and CF2a (this gate,
[r18](../specs/mutation_pipeline.spec.md)) shipped product code that
changed `mutagen.mutation_pipeline` behavior on the epic branch, but the
originating tickets carried no `Advances:` field, so no subject spec or
decision was updated — `mix spec.check`'s branch guard then flagged the
change as cross-cutting with no decision file. This decision closes that
gap and records the posture both halves implement.

## Decision

- **Gate and warn, do not block.** When the resolved `max_concurrency`
  is `> 1`, `MutationRunner.run/1` emits a ONE-TIME stderr EXPERIMENTAL
  warning that names the risk (incorrect kill/survive classification +
  corrupted coverage on real ExUnit/`:cover` backends) and states the
  safe path is the default, `--max-concurrency 1`. It is SILENT for
  `max_concurrency == 1`. The default stays fully-serial / v1.0-equivalent
  (r15). `> 1` remains an explicit, warned opt-in for callers who have
  arranged collision-free input.
- **Document the gate everywhere the flag is described.** `mix help
  mutagen` (the `Mix.Tasks.Mutagen` option text) and the README both mark
  `--max-concurrency > 1` EXPERIMENTAL with the same risk language. The
  spec, help, and README carry one consistent story.
- **Restore must respect sibling liveness on out-of-band worker death.**
  CF1 (r17): on a per-site outer-task `{:exit}`, the runner tears down +
  drains all sibling per-site tasks FIRST, THEN sweeps all scoped modules
  through BeamCache restore. The sweep is never concurrent with a live
  sibling — loading an original over a module a sibling is still testing
  its mutant on is exactly the shared-Code.Server hazard above, surfacing
  under worker death rather than timeout.
- **Defer the real fix to CF2b.** The OS-process-sharding architecture
  (the only shape that removes the shared-global-state hazard) is tracked
  separately as **mutagen-33b.3 (CF2b)**. Until it lands, `> 1` carries
  the experimental warning rather than a correctness guarantee.

## Consequences

**Positive**:

- Users get the speed of parallel dispatch as an informed opt-in,
  without the tool silently emitting wrong kill/survive verdicts to an
  unwarned caller.
- The honest default (`1`) and the documented hazard keep the
  correctness contract intact for the path almost everyone runs.
- The branch-guard cross-cutting-change finding is resolved: the spec
  delta records the behavior CF1/CF2a shipped, and this decision records
  why the gate-and-warn posture was chosen over blocking or a full fix.

**Negative / accepted**:

- `--max-concurrency > 1` is fast but not trustworthy on real
  ExUnit/`:cover` backends until CF2b. The warning is the only guard; a
  caller who ignores it can get corrupted results.
- The eventual OS-process-sharding fix is a larger build than an in-VM
  tweak would have been — but in-VM isolation is not achievable against
  the singleton Code.Server / `:cover` services, so the larger build is
  the real cost of correctness here, not avoidable complexity.
