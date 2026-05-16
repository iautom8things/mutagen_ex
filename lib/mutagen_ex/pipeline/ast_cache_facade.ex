defmodule MutagenEx.Pipeline.AstCacheFacade do
  @moduledoc """
  Behaviour for the `:ast_cache` slot of the `Mix.Tasks.Mutagen`
  dispatch table.

  Production default: `MutagenEx.AstCache`. The Mix task calls
  `mod.load(files, opts)` once with the unique source files derived
  from resolved scope records plus the cited test files (post-`.25.3`).

  ## Callback contract

  The `load/2` signature is **frozen** per
  `mutagen.decision.ast_cache_facade_preserved`: a flat
  `files :: [String.t()]` list plus a keyword `opts`. Adapters MUST NOT
  add positional arguments or change the success return shape. The cache
  entry shape is `{Macro.t(), String.t()}` — same as v1 — and there is
  no category tag in the entry.

  ## Opts convention (advisory, not part of the @callback)

  Production callers may pass `categories: %{atom => [String.t()]}` as
  diagnostic metadata. Adapters that don't use it should ignore it; the
  flat `files` list is authoritative.
  """

  @doc "Load AST + source text for each file."
  @callback load(files :: [String.t()], opts :: keyword()) ::
              {:ok, map()}
              | {:error, atom(), map()}
end
