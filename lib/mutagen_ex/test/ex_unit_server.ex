defmodule MutagenEx.Test.ExUnitServer do
  @moduledoc """
  Default `MutagenEx.Test.ExUnitServerFacade` implementation — thin
  wrapper over `ExUnit.Server`.

  Tests swap a different module via the `:ex_unit_server` config key.
  """

  @behaviour MutagenEx.Test.ExUnitServerFacade

  @impl MutagenEx.Test.ExUnitServerFacade
  defdelegate add_module(module, cfg), to: ExUnit.Server
end
