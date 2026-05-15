defmodule MutagenEx.Test.ExUnitFacade do
  @moduledoc """
  Behaviour for the `ExUnit` test seam used by `MutagenEx.Baseline`,
  `MutagenEx.CoverageRunner`, `MutagenEx.MutationRunner`, and
  `MutagenEx.MutationRunner.MutationLoop`.

  Production code calls `ExUnit.configure/1` and `ExUnit.run/0`; the
  facade exists so tests can swap a fake module (with the same callback
  surface) for either of those without resorting to `apply/3` at the call
  site.

  ## Default

  `MutagenEx.Test.ExUnit` delegates to the real `ExUnit` module.

  ## Usage

  Per-phase config maps carry an `:ex_unit` key naming the facade module
  to use; production code threads `MutagenEx.Test.ExUnit` (the default
  via `Map.get(cfg, :ex_unit, MutagenEx.Test.ExUnit)`), and tests pass
  their own module implementing this behaviour.
  """

  @doc """
  Apply ExUnit configuration. Mirrors `ExUnit.configure/1`.

  Production code passes a keyword list with at minimum `:max_cases` and
  `:seed`. The runner additionally forwards `:include` and `:exclude`
  from the resolved test filter.
  """
  @callback configure(opts :: keyword()) :: any()

  @doc """
  Run ExUnit. Mirrors `ExUnit.run/0`.

  Returns a map matching `ExUnit.run/0`'s shape (subset):
    %{failures: non_neg_integer(), total: non_neg_integer(),
      excluded: non_neg_integer(), skipped: non_neg_integer()}
  """
  @callback run() :: map()
end
