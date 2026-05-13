---
id: mutagen.decision.no_pretty_output_v1
status: accepted
date: 2026-05-13
affects:
  - mutagen.cli
  - mutagen.json_schema
---

# JSON is the only output surface in v1; `--no-json` deferred to v1.1

## Context

The spec listed `--no-json` (pretty terminal output) as Should-Have. The
global contracts mentioned it for "human runs." Scope Question 3 in the
refined plan asked whether to build it in v1 or defer.

The case for v1: humans invoking the tool directly want readable output.
A long JSON document piped to a terminal is hostile.

The case against v1: the primary consumer is an LLM verifier judge, not
a human. Humans can pipe through `jq` for v1 (the JSON is well-formed
and the schema is documented). Adding a pretty renderer is a
non-trivial new code surface (color, line wrapping, progress indicators)
that competes with the more important work of getting the in-process
pipeline correct.

## Decision

- **`--no-json` is deferred to v1.1.** It is not part of the v1 CLI
  surface.
- **JSON is the only output format.** Stdout (default) or `--json <path>`.
- **Supplying `--no-json` to v1 is an error** with `reason:
  :flag_not_supported_in_v1` — not a silent ignore. Users who try it
  should learn immediately rather than have their command swallowed.

## Consequences

**Positive**:

- One less code surface to build, test, and maintain in v1.
- Humans who want pretty output have a workaround (`jq`) that lands them
  in familiar tooling.
- The decision frees a half-day of S1/S6 work.

**Negative**:

- Human invocation is slightly worse in v1 than the spec sketch implied.
- v1.1 needs to add this back without breaking the JSON surface.
  Practical mitigation: when `--no-json` ships, the JSON path remains
  the default; pretty output is opt-in only.
