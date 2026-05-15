defmodule MutagenEx.Pipeline.AstCacheFacade do
  @moduledoc """
  Behaviour for the `:ast_cache` slot of the `Mix.Tasks.Mutagen`
  dispatch table.

  Production default: `MutagenEx.AstCache`. The Mix task calls
  `mod.load(files, opts)` once with the unique source files derived
  from resolved scope records.
  """

  @doc "Load AST + source text for each file."
  @callback load(files :: [String.t()], opts :: keyword()) ::
              {:ok, map()}
              | {:error, atom(), map()}
end
