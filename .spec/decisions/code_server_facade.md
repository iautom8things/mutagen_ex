---
id: mutagen.decision.code_server_facade
status: accepted
date: 2026-05-15
affects:
  - mutagen.mutation_pipeline
---

# MutagenEx.Test.CodeServer facade behaviour

## Context

`mutagen-wrd.25` replaces `Code.compile_quoted/2` in the restore path with
a binary swap via `:code.load_binary/3`, using `:code.get_object_code/1`
to capture the original `.beam` snapshot (see
mutagen.decision.per_run_beam_cache).

Without indirection, every test exercising `BeamCache` becomes an
integration test against the live BEAM module table:

- `:code.get_object_code/1` reads from disk and the loaded-module table.
- `:code.load_binary/3` mutates the loaded-module table globally.
- A test that fails between snapshot and restore leaves a foreign binary
  loaded for the remainder of the test run — silently breaking subsequent
  tests in the same `mix test` invocation.

The testability red-team ([04b-testability-review.md]) flagged this as a
CRITICAL: every BeamCache test would need to either tolerate state leakage
or restore by hand at the end of each test. Neither is acceptable.

The project already has a precedent for this pattern: `MutagenEx.Test.Compiler`
is a behaviour-backed facade over `Code.compile_quoted/2`, with
`cfg.compiler` selecting the implementation. Tests pass a stub that
records the call without touching the BEAM. The same shape works for
`:code.get_object_code/1` and `:code.load_binary/3`.

## Decision

A new behaviour module `MutagenEx.Test.CodeServerFacade`:

```elixir
defmodule MutagenEx.Test.CodeServerFacade do
  @callback get_object_code(module()) ::
              {module(), binary(), filename :: charlist()}
              | :error
  @callback load_binary(module(), filename :: charlist(), binary()) ::
              {:module, module()}
              | {:error, term()}
end
```

The production implementation `MutagenEx.Test.CodeServer` delegates to the
`:code` module directly. Tests can inject a stub that records calls or
returns canned responses.

`cfg.code_server` selects the implementation (defaults to
`MutagenEx.Test.CodeServer`). The pattern mirrors `cfg.compiler` exactly —
same call shape, same default, same override convention.

`BeamCache.snapshot/3` and `BeamCache.restore/3` take a `code_server`
argument (or read it from cfg, depending on call site). The facade is
threaded through the same way `cfg.compiler` is threaded through
`safe_compile_quoted/3`.

## Consequences

**Positive:**
- BeamCache becomes unit-testable. A test injects a stub that returns
  a known binary; the test asserts the cache stores it and replays it
  on restore. No live BEAM mutation.
- Concurrent-snapshot tests can use a stub that introduces controlled
  delay, exercising the TOCTOU pre-pass without flakiness.
- Mirrors an existing convention — zero new patterns for the codebase.

**Negative:**
- One more behaviour module, one more cfg field. Small surface growth.
- Production code paths must call through the facade (`code_server.load_binary(...)`),
  not directly (`:code.load_binary(...)`). Easy to forget in a future
  patch; mitigated by code review and the integration test in S5.

## Related

- mutagen.decision.per_run_beam_cache — the BeamCache shape this seam
  serves.
- `MutagenEx.Test.Compiler` — the existing parallel facade this mirrors.
