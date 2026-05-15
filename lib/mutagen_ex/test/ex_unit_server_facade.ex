defmodule MutagenEx.Test.ExUnitServerFacade do
  @moduledoc """
  Behaviour for the `ExUnit.Server` test seam used by
  `MutagenEx.MutationRunner.MutationLoop`.

  Per-mutation test cycles re-register cited test modules with
  ExUnit.Server before each `ExUnit.run/0`, because the server consumes
  its registered-module list per run. The facade exists so tests can
  swap a fake module recording the calls.

  ## Default

  `MutagenEx.Test.ExUnitServer` delegates to `ExUnit.Server`.
  """

  @doc """
  Add a test module to the ExUnit server's registered list. Mirrors
  `ExUnit.Server.add_module/2`.

  The `cfg` map matches the shape ExUnit's server expects, validated
  against Elixir 1.19.5 / OTP 28 in the S2 spike:
    %{async?: false, group: nil, parameterize: nil}
  """
  @callback add_module(module :: module(), cfg :: map()) :: any()
end
