---
id: mutagen.decision.report_text_policy
status: accepted
date: 2026-11-19
affects:
  - mutagen.cli
  - mutagen.json_schema
  - mutagen.mutation_pipeline
---

# Keep host diagnostic text out of default reports

## Context

Mutagen runs host test code in the same BEAM. Test output and exception
messages can contain environment secrets and query parameters with no
credential markers. CI publishes reports to readers who might only have
access to the repository.

## Decision

JSON and NDJSON keep source excerpts, subject to a byte cap and control
character removal, as well as structured facts about tests and aborts.
The source switch omits site source fields for wider sharing. The report
boundary omits host diagnostic bodies by default. Opted-in diagnostic
bodies and structured strings use best-effort credential redaction once
per serialized field, before truncation. Compile-time code can raise
arbitrary messages, so compile errors retain only a fixed diagnostic and
structured facts in default reports.

The default console Logger handler writes to the stderr device outside
per-mutant capture. The task routes ordinary host I/O to stderr and
keeps the original report device separately. Report files have mode
0600. Test timeouts only reap site-owned processes and warn if the site
lost pre-existing host processes.

These rules replace the startup summary, default redaction, and
process-group cleanup provisions of the host test setup decision.

## Consequences

Source excerpts can include committed secrets. Structured facts can
include text from test names and filters. Pattern redaction covers known
shapes and does not establish that text is free of secrets.

Host programs that write directly to fd 1 can still reach stdout.
CI uploads the report file rather than capturing stdout or stderr.
