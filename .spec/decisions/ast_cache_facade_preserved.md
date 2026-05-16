---
id: mutagen.decision.ast_cache_facade_preserved
status: accepted
date: 2026-05-15
affects:
  - mutagen.coverage
---

# AstCache extends to test files without changing the facade callback signature

## Context

`mutagen-wrd.25` extends `MutagenEx.AstCache` to cover not only scope files
but also cited test files (the `test_filter.files` set), so that
`Baseline.detect_async_modules/1` reads from cache rather than re-parsing
from disk. The initial architecture proposed:

1. A new public function `AstCache.files_by_category/2` exposing per-category
   filtering.
2. A new entry shape `{ast, source, category}` (3-tuple instead of 2-tuple).
3. A revised `Pipeline.AstCacheFacade` `@callback` signature accepting
   categorised input `[{:scope, files}, {:test, files}]`.

The technical red team ([04a-technical-challenges.md, finding #3]) flagged
the callback signature change as a breaking change: test fakes implementing
the facade behaviour would silently fail to compile against the new
signature. Production callers were audited; the test surface was not.

The scope auditor independently noted that consumers don't actually need to
filter by category — they look up by file path. The category tag is metadata
in search of a use case.

## Decision

The `Pipeline.AstCacheFacade` `@callback` signature is preserved verbatim
from its pre-`.25` shape:

```elixir
@callback load(files :: [String.t()], opts :: keyword()) ::
            {:ok, map()} | {:error, atom(), map()}
```

Categorisation is **input-only metadata**, accepted by the production
implementation's `load/2` via an option:

```elixir
AstCache.load(scope_files ++ test_files,
  categories: %{scope: scope_files, test: test_files})
```

The categories option is for diagnostics and is NOT exposed via the
facade callback. Test fakes that implement the existing 2-arg `load/2`
callback continue to work unchanged.

The cache entry shape stays a 2-tuple `{Macro.t(), String.t()}` — no
category stored. Consumers that need to know "is this a test file?" check
the file path against `test_filter.files` (which is already in the cfg).

The new `AstCache.files_by_category/2` function is cut entirely.

`Baseline.detect_async_modules/1` reads via `AstCache.get(cache, file)`
and consumes the returned `{ast, _source}` directly. If the cache miss
returns `:error`, the function falls back to reading from disk
(preserving today's behaviour as a safety net for cache misses).

## Consequences

**Positive:**
- Zero breaking changes to the facade behaviour. Existing test fakes work.
- Cache entry shape unchanged → no churn across 4+ consumer call sites.
- `files_by_category/2` deletion saves a public-API surface that nobody
  needed.
- Backward-compat: a caller passing only a flat file list (no categories
  opt) gets the same result as pre-`.25`.

**Negative:**
- The "category" abstraction is invisible to consumers — anyone debugging
  cache misses has to cross-reference against `test_filter.files` to know
  if a missing entry is a scope file or a test file. (Mitigated by
  diagnostic logging in the production `load/2` implementation.)

## Related

- mutagen.coverage — owns the AstCache contract.
- F18 (Baseline test-file re-read) — closed by S2 of `.25` via this decision.
- F19 (TestSelector tag re-read) — descoped to `.25-fu1` per
  mutagen.decision.f19_descoped (independent of this decision, but
  related: both deal with cache extension).
