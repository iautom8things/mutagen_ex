---
id: mutagen.decision.drop_telemetry_event_api
status: accepted
date: 2026-06-23
affects:
  - mutagen.mutation_pipeline
  - mutagen.cli
supersedes:
  - The `:telemetry` event clause of mutagen.mutation_pipeline.r15
---

# Drop the `:telemetry` event API; per-site observation rides `:on_site_completed`

## Context

`mix mutagen` ships as a globally-installed Mix archive
(`mix archive.install`, see [mutagen.cli.r16](../specs/cli.spec.md)). A
Mix archive bundles only the owning app's own ebin — it cannot carry
dependencies. `:telemetry` was the tool's only runtime dependency, so
from an archive-installed host `Application.ensure_all_started(:mutagen_ex)`
failed (`:telemetry` was never on the code path) and `mix mutagen`
aborted with `runtime_load_failed`.

The `:telemetry` event surface was T3 review-polish (bundled with the
parallel loop and NDJSON streaming in bw mutagen-wrd.30). It was
**producer-only by design**: the library shipped no subscriber, and the
foundational [mutagen.decision.no_pretty_output_v1](no_pretty_output_v1.md)
frames the canonical consumer as an LLM judge reading JSON, not a
telemetry poller. The only in-tree consumer of the events was the
human-readable per-site progress feed.

The runner already exposes a first-class `:on_site_completed` callback
(the per-site observation seam NDJSON streaming rides). It fires once
per site, in input order, in both `--max-concurrency 1` (in-caller) and
`> 1` (parallel) modes. The progress feed has the same per-site cadence
and ordering needs as the streamer, so it can ride the same seam.

## Decision

- **The `:telemetry` event API is removed.** `MutagenEx.Telemetry` is
  deleted; the `[:mutagen_ex, :run | :coverage | :baseline |
  :enumeration | :site, …]` events are no longer emitted.
- **`:telemetry` is removed as a runtime dependency.** It is not a
  started application of `:mutagen_ex`. The runtime surface is dep-free
  so the archive install path works.
- **`:on_site_completed` is the single per-site observation seam.** Both
  NDJSON streaming (`--stream`) and the human-readable progress feed
  (default-on-TTY, `--no-progress` to suppress) are driven by it. The
  Mix task composes the two consumers around one callback. The progress
  reporter is stateful — it keeps a running site index (the callback
  payload carries `status`, `file`, `line`, `mutator`, `id` but not
  `index`/`total`, which the Mix task supplies from `length(sites)` and
  a closed-over counter).

## Consequences

**Positive**:

- `mix archive.install` produces a working `mix mutagen` — the whole
  point ([mutagen.cli.r16](../specs/cli.spec.md) archive context).
- One fewer dependency to vet, lock, and bundle.
- A single per-site seam instead of two parallel observation
  mechanisms (telemetry events + callback) that had to be kept in sync.

**Negative / accepted**:

- External telemetry subscribers (none shipped, none known in-tree)
  lose the event stream. Re-introducing observability later would mean
  a new seam, not a revival of the removed events.
- The progress feed no longer gets a free `index`/`total` from event
  metadata; the Mix task derives them. This is a small, contained piece
  of state in the callback wrapper.
