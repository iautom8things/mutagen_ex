---
id: mutagen.decision.scope_syntax_simplified
status: accepted
date: 2026-05-13
affects:
  - mutagen.cli
  - mutagen.scope_resolution
---

# `--scope` accepts file, module, or `M.f/arity` — no colon form

## Context

Initial spec sketches allowed a colon-disambiguated scope:
`lib/foo.ex:Foo.Bar.baz/1`. The intent was to let users name a specific
module in a multi-`defmodule` file when the module's name alone might be
ambiguous in a large codebase. Red-team's M-T2 finding: this is solving
imagined ambiguity with concrete user-surface complexity. In practice, a
module name is globally unique inside a project (Elixir requires it), so
the file disambiguator carries no information the module name doesn't
already.

L-T2 added: arity is sometimes implicit (`Foo.bar` could be `bar/1` or
`bar/2`). The resolver needs `bar/1` explicitly, not best-effort inference.

## Decision

`--scope <target>` accepts exactly three target shapes:

1. **File path** — anything ending in `.ex` (e.g., `lib/foo.ex`).
2. **Module name** — `Module.Name` (no `/arity`, no leading path).
3. **MFA** — `Module.Name.function/arity`. Arity is required.

The colon form (`file:Module`) is rejected with a structured error
`reason: :colon_syntax_unsupported`. The arity-less MFA form (`Module.fn`)
is rejected with `reason: :arity_required`.

Multi-`defmodule` files are handled by the module-name target: the resolver
picks the matching `defmodule` block from whichever file contains it.

## Consequences

**Positive**:

- Fewer flag formats to document, parse, validate, and explain.
- The judge prompt is simpler: there's one canonical way to refer to a
  module.
- Removes a class of user error (typo in the colon part).

**Negative**:

- A future use case that genuinely needs file-disambiguated scope (e.g.,
  inside a generated module with non-unique names) would need a syntax
  extension. v1 explicitly defers this; we'll add it in v1.x if a real
  case appears.
- "Range scope" (`lib/foo.ex:10-50`) is also deferred — listed in the
  spec's Open Questions and not part of v1.
