defmodule MutagenEx.Pipeline.BaselineFacade do
  @moduledoc """
  Behaviour for the `:baseline` slot of the `Mix.Tasks.Mutagen`
  dispatch table.

  Production default: `MutagenEx.Baseline`. The Mix task calls
  `mod.run(input)` once with the seed + resolved test filter.
  """

  @doc "Run the baseline test phase on unmutated code."
  @callback run(input :: map()) ::
              {:ok, map()}
              | {:error, atom(), map()}
end
