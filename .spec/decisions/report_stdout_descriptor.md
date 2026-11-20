---
id: mutagen.decision.report_stdout_descriptor
status: accepted
date: 2026-11-20
affects:
  - mutagen.cli
  - mutagen.mutation_pipeline
---

# Isolate the report on its own descriptor

## Context

OTP prints a handler failure with `erlang:display/1`. The write goes to
file descriptor 1 and bypasses Erlang's registered I/O devices. It can
happen while running a test or while cleaning up after the final report.

## Decision

After Mix enters the task, start one host VM with its stdout directed
to stderr, its original stdin, and a dedicated pipe for report bytes.
The first VM forwards
the pipe to stdout and propagates the host VM's exit code. Host setup,
coverage, baseline, mutation and cleanup all run together in the host
VM. The registered user device continues to route requests inside it.

On POSIX, a fixed shell command sets up the descriptors before starting
the host VM. Command-line values pass as separate arguments. The Mix
archive keeps its existing dependency set.

## Consequences

The task can write JSON or NDJSON during the run. The host can still
write diagnostics after the final report. Mix startup in the first VM
happens before the task starts.
