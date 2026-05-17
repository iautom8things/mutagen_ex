---
id: mutagen.decision.details_always_present
status: accepted
date: 2026-05-17
affects:
  - mutagen.json_schema
---

# JSON `details` field is always present, `{}` on success

## Context

Pipeline phases already build diagnostic context maps when they fail:

```elixir
# lib/mutagen_ex/coverage_runner.ex
{:error, :test_file_load_failed,
  %{file: file,
    message: "could not load test file ..."}}
```

But `JsonReporter.to_wire/1` never serializes that map — the emitted JSON
carries only `abort_reason`, leaving downstream users with no diagnostic
context. A downstream user seeing
`{"abort_reason":"test_file_load_failed", ...}` cannot tell which file
failed or why.

The fix is to thread the phase-supplied details map onto `%Report{}` and
serialize it. The shape question is: should the JSON `details` field
appear on every document (with `{}` on success), only on aborts, or only
when populated?

## Decision

**`details` is always present, always a map.**

- On `aborted: false` runs: `details == %{}` (empty map).
- On `aborted: true` runs: `details` contains the phase-supplied
  diagnostic context (keys vary by `abort_reason`; phases own their
  shape).

Atom values are stringified at the wire boundary. Binary leaves pass
through the existing `r10` truncation + `r11` redaction sanitizer
pipeline before emission.

## Consequences

### Positive

- **Shape stability for consumers.** A consumer parsing the JSON can
  write `doc["details"]["file"]` once without branching on key
  presence. Mirrors the existing convention for `warnings` (always
  present, empty list when nothing) and `truncated` (always present,
  `false` by default).
- **Additive vs. v1 schema.** The schema spec explicitly says "adding
  fields is allowed; removing or renaming requires a version bump."
  Always-present-with-`{}`-default is additive — a v1 consumer that
  ignored unknown fields keeps working; a v1 consumer that strictly
  validated keys needs a one-line update.
- **Sanitizer reuse.** No new sanitizer rules. Phase-supplied details
  flow through the same truncate + redact path as
  `mutation.results[].warnings[]`.

### Negative

- **Fixture-update cost.** Every existing golden fixture under
  `test/mutagen_ex/golden/*.json` (17 files) needs the `"details": {}`
  or populated-`"details": {...}` key added in the same commit that
  changes `to_wire/1`. Mechanical but tedious.
- **Wire-size growth on success.** Every successful run's document
  grows by exactly `"details":{}` (10 bytes). Negligible.

### Alternative considered

**Present only on abort.** Rejected because consumers parsing the JSON
would need to defensively check for key presence before dereferencing
— and shape variance across success/abort variants is exactly the
brittleness this decision avoids.

**Schema version bump to v2.** Rejected because the existing schema
docs explicitly classify additive field changes as non-breaking. Bumping
v1 → v2 for one additive field would penalise existing v1 consumers
unnecessarily and would require simultaneous updates to the version
literal in `JsonReporter`, every golden fixture, and the README's
schema documentation.
