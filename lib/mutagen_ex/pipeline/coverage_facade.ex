defmodule MutagenEx.Pipeline.CoverageFacade do
  @moduledoc """
  Behaviour for the `:coverage` slot of the `Mix.Tasks.Mutagen`
  dispatch table.

  Production default: `MutagenEx.CoverageRunner`. The Mix task calls
  `mod.run(input)` once with the seed + in-scope modules + test
  filter.
  """

  @doc "Run the coverage phase against the cited tests."
  @callback run(input :: map()) ::
              {:ok, map()}
              | {:error, atom(), map()}
end
