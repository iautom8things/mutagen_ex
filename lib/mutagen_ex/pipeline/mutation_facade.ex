defmodule MutagenEx.Pipeline.MutationFacade do
  @moduledoc """
  Behaviour for the `:mutation` slot of the `Mix.Tasks.Mutagen`
  dispatch table.

  Production default: `MutagenEx.MutationRunner`. The Mix task calls
  `mod.run(input)` once with the seed, timeout, sites, ast_cache, and
  test filter.
  """

  @doc "Run the mutation loop over the enumerated sites."
  @callback run(input :: map()) ::
              {:ok, map()}
              | {:error, atom(), map()}
end
