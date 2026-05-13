---
id: mutagen.decision.json_reporter_owns_error
status: accepted
date: 2026-05-13
affects:
  - mutagen.json_schema
  - mutagen.cli
---

# `JsonReporter` owns both success and error JSON

## Context

The original architecture had two reporter modules:

- `JsonReporter` — produces the success-shape document.
- `ErrorReporter` — produces the error-shape document for bad-input exits.

The scope audit's B1 finding: this is two modules synced by convention.
Both produce JSON of the same schema family (`version: "1"`, same top-level
keys). Splitting them creates two places where the schema must agree, with
no compiler help if they drift.

The testability review's L-Tt3 finding (Mix-task collaborator injection)
also argued that neither reporter should do I/O directly — both should
return `{iodata, exit_code}` and let the Mix task perform the actual
`IO.puts` / `System.halt`. This makes the state-machine error paths
unit-testable without spawning processes.

## Decision

Merge `ErrorReporter` into `JsonReporter`. The single module exposes:

- `emit_report(success_report :: %Report{}) :: {iodata, 0}` — full pipeline
  result.
- `emit_error(report :: %Report{}, abort_reason :: atom) :: {iodata,
  non_neg_integer}` — partial / abort variant.

Both produce documents conforming to
[mutagen.json_schema](../specs/json_schema.spec.md). Neither calls
`IO.puts`, `IO.write`, `System.halt`, or `File.write!`. The Mix task is the
only place I/O happens.

## Consequences

**Positive**:

- One place owns the schema. Adding a field happens in one module, not two.
- Round-trip testing is simpler: feed a fixture `%Report{}`, get iodata,
  compare to a golden file.
- The state machine in the Mix task can be unit-tested by injecting a fake
  reporter via the private dispatch table (per L-Tt3).

**Negative**:

- The module is slightly larger (a single `case` on `%Report{aborted:
  true | false}`).
- Removing `ErrorReporter` means the term "error-shaped JSON" no longer
  maps to a distinct module name. Documentation refers to "the
  abort-variant" or "the partial-report shape" instead.
