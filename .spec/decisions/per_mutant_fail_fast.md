---
id: mutagen.decision.per_mutant_fail_fast
status: accepted
date: 2026-11-19
affects:
  - mutagen.cli
  - mutagen.coverage
  - mutagen.json_schema
  - mutagen.mutation_pipeline
---

# Stop each mutant run at its first failure and judge deadlines by completion time

## Context

One failed cited test is enough to kill a mutant, yet every per-site run
executed the whole cited suite. Slow suites paid for tests that could not
change the verdict. A mutant whose later tests hung reached the deadline
and was reported as a timeout although a test had already failed.

The timeout path had an open defect, recorded against
mutagen.mutation_pipeline.r4 in mutagen.decision.ancora_migration. After
the deadline, a reply returned during the grace window or racing
`terminate_child/2` still classified the site. A late clean reply
reported `:survived` and skipped the purge and the taint.

Each phase also called `ExUnit.configure/1` before it loaded the cited
files. A test helper or test file that configured ExUnit while loading
replaced the forced settings, and a cold load registered each module
twice. Baseline reported a failure count with an empty failure list.

## Decision

- Fail-fast is the default. The mutation phase uses `max_failures: 1`
  for each per-site run, and `--no-fail-fast` uses `:infinity`.
  Baseline and coverage always use `:infinity`. Reports record the mode
  in `meta.fail_fast`, which is `true` when the run stops before
  argument parsing yields a mode.
- Only a reply the task completed by the deadline classifies a site. The
  task stamps its reply with monotonic time. After the deadline, shutdown
  only reaps the task, and its reply is discarded.
- A site that passes its deadline is `:timeout`. In fail-fast mode, a
  failure that Mutagen's formatter recorded at or before the deadline
  makes the site `:killed` with a warning. Every deadline outcome purges
  the scoped modules and taints the next site.
- Each phase loads the cited files first. It then sets `max_cases: 1`,
  the seed, the failure cap and the resolved include and exclude in the
  ExUnit application environment, keeps the loaded formatters and appends
  its failure formatter where it collects failures. On every exit it
  restores the post-load value of each key it set and of `:trace`.
  Other host options stay active.
- With an explicit cited module list, baseline and coverage discard the
  registrations queued by loading and register each module once. In
  serial mode the runner empties `ExUnit.Server` after a deadline, so a
  runner cancelled during startup cannot break the next registration.
- Baseline lists every test ExUnit counted as failed, including tests
  invalidated by `setup_all` and tests of a module whose teardown failed.
  The error details carry the same `{module, name}` objects.

This amends two accepted decisions. In mutagen.decision.timeout_handling,
the rule that classification stays `:timeout` whichever phase cleared the
task gains the fail-fast exception above, and a grace-window reply no
longer counts. In mutagen.decision.serial_execution_and_seed, the forced
settings gain a failure cap, apply after loading and last only for the
phase.

## Consequences

Fail-fast assumes the cited tests run independently. A capped run skips
the tests after its first failure. If a skipped test sets up or cleans up
state for other tests, the next mutant starts from a state that baseline
and coverage never saw, and its verdict can change in either direction.
Suites with such dependencies already depend on ExUnit's seed order and
should use `--no-fail-fast`. Skipped tests can also change per-site
warnings and taint. A shorter mutation phase can complete more sites
within the same `--budget-ms`.

The failure formatter finds the runner through the ancestry of ExUnit's
formatter supervisor and reads its callback from the ExUnit options. If a
later ExUnit changes either, the formatter fails to start. Deadline kills
then revert to timeouts and baseline failure lists come back empty. The
verdicts stay conservative, and the red-baseline tests detect the change.

Experimental parallel mode still shares `ExUnit.Server` and the Code
Server between sites. The registry drain runs only in serial mode.
