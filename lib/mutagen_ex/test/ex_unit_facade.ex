defmodule MutagenEx.Test.ExUnitFacade do
  @moduledoc """
  Behaviour for the `ExUnit` test seam used by `MutagenEx.Baseline`,
  `MutagenEx.CoverageRunner`, `MutagenEx.MutationRunner`, and
  `MutagenEx.MutationRunner.MutationLoop`.

  The facade lets tests replace `ExUnit.run/0` while each phase manages
  the actual ExUnit configuration.

  ## Default

  `MutagenEx.Test.ExUnit` delegates to the real `ExUnit` module.

  ## Usage

  Per-phase config maps carry an `:ex_unit` key naming the facade module
  to use; production code threads `MutagenEx.Test.ExUnit` (the default
  via `Map.get(cfg, :ex_unit, MutagenEx.Test.ExUnit)`), and tests pass
  their own module implementing this behaviour.
  """

  @doc """
  Run ExUnit. Mirrors `ExUnit.run/0`.

  Returns a map matching `ExUnit.run/0`'s shape (subset):
    %{failures: non_neg_integer(), total: non_neg_integer(),
      excluded: non_neg_integer(), skipped: non_neg_integer()}
  """
  @callback run() :: map()
end
