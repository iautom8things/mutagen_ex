---
id: mutagen.decision.changed_code_run
status: accepted
date: 2026-11-19
affects:
  - mutagen.cli
  - mutagen.scope_resolution
  - mutagen.test_selection
  - mutagen.coverage
  - mutagen.mutation_pipeline
  - mutagen.json_schema
---

# Plan changed code before booting the host

## Context

A pull request needs feedback on changed runtime sites. Running the full
host setup for an empty or cosmetic change costs time and can fail on
unrelated configuration. A narrow test selection can miss an existing test
that kills a mutant.

## Decision

Read Git and compare group fingerprints before host boot. Run only runtime
sites with measured coverage. Record the unresolved sites, incomplete reads,
and selection evidence for later consumers.

With automatic test selection, find more tests by text after each round of
survivors. Baseline each new file on the original code before accepting it.
Keep the same ExUnit server and register only the cases selected for each
pass. Add newly covered sites to the pass that discovers their coverage.

Keep per-mutant fail-fast on for changed-code runs. When skipping a test
leaves cross-test state behind, a later mutant can be killed falsely. This
can cause the report to miss a survivor.
Users can request full mutation passes with `--no-fail-fast`.

Derive the default mutant deadline from the unmutated baseline of the
tests that will judge it. Use ten times the measured duration with a
five-second floor and a thirty-second ceiling. An explicit
`--timeout-ms` supplies the deadline directly. A deadline expiry
kills a mutant only if the runner recorded a failure before expiry.

## Consequences

The report records one final result per mutation. Later passes extend the
test selection and retain the steps that ran. Text matching can miss tests
that exercise a module indirectly. File caps and rejected tests remain
visible in the report. A narrow run with no tests still records uncovered
runtime sites.
