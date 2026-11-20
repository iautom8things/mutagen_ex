---
id: mutagen.decision.json_report_channel
status: accepted
date: 2026-11-20
affects:
  - mutagen.cli
  - mutagen.json_schema
---

# Use the JSON file for machine-readable reports

## Context

The Mix task and the host run in one BEAM. The VM can write native
diagnostics to stdout before, during or after report generation.

## Decision

`--json PATH` is the guaranteed report channel. The file contains exactly
one JSON document, or NDJSON with `--stream`, regardless of host output.

Without `--json`, Mutagen writes the report to stdout and routes the
`:user` device and known console logger handlers to stderr. The VM can
write directly to file descriptor 1, including when an OTP logger
handler crashes. In-process I/O routing cannot intercept those writes.
Use `--json PATH` and `--summary PATH` in CI.

## Consequences

The task preserves the host's Mix startup, stdin and signal handling.
Atomic file writes keep console output out of the report.
