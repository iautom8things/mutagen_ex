---
id: mutagen.decision.serial_execution_and_seed
status: accepted
date: 2026-05-13
affects:
  - mutagen.cli
  - mutagen.coverage
  - mutagen.mutation_pipeline
---

# Serial test execution and `--seed` semantics

## Context

Two related questions surfaced during red-team:

- **H-T1 — Baseline + coverage async semantics unspecified.** ExUnit defaults
  to `max_cases: System.schedulers_online()`. Running cited tests in parallel
  introduces non-determinism: a `setup_all` race could produce different
  results between the baseline run and a mutation run, and a flaky test
  might look like a survived mutation.
- **H-T4 — ExUnit seed default is random.** Test order changes between runs
  by default. Tests that depend on each other's side effects (an anti-
  pattern, but common in older codebases) would produce different pass/fail
  patterns between runs.

Scope Question 1 asked: what does `--seed` mean in v1, given there's no
sampling or parallelism for the seed to randomize?

## Decision

- **Force `max_cases: 1` for all phases.** Baseline, coverage, and every
  per-mutation run all execute tests strictly serially. There is no
  `--parallel` flag in v1.
- **`--seed <n>` controls `ExUnit.configure(seed: n)`.** This determines
  test ordering, which is the only seed-affected concern at serial-execution.
  Default value is `0` (deterministic ordering across runs without flags).
- **`--seed` is propagated to every phase** that runs tests: baseline,
  coverage, and each mutation run. The JSON output's `meta.exunit_seed`
  echoes the value.
- **Async test modules trigger a warning.** If a cited test module was
  declared `async: true`, a warning naming that module is added to the JSON's
  top-level `warnings` array. The pipeline still runs serially regardless.

## Consequences

**Positive**:

- Determinism across runs. Same `{source, --tests, --scope, --seed}` always
  produces the same pass/fail classification per site.
- Simpler timeout handling: only one test process can be running at any
  moment, so brutal-kill on timeout is unambiguous.
- The `--seed` flag has well-defined semantics (rather than being a no-op
  forward-compat field, which was Scope Question 1 option (a)).

**Negative**:

- Slower than parallel execution. For large suites this matters; v1.1 may
  add a parallel mode with its own seed semantics, but the spec's primary
  user (an LLM verifier judge) does not care.
- `async: true` is silently overridden. Users who structured their suites
  around it lose that property in this tool. The warning is the visible
  signal; they can fix `setup_all` ordering deps if it matters.
