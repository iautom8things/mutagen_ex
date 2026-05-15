defmodule MutagenEx.Test.ExUnit do
  @moduledoc """
  Default `MutagenEx.Test.ExUnitFacade` implementation — thin wrapper
  over the real `ExUnit` module.

  Production code calls into this module instead of `ExUnit` directly so
  the call sites can be compile-time-dispatched against a behaviour
  (`MutagenEx.Test.ExUnitFacade`) rather than `apply(mod, fun, args)`
  with no Dialyzer leverage.

  Tests swap a different module (implementing the same behaviour) via
  the `:ex_unit` config key.
  """

  @behaviour MutagenEx.Test.ExUnitFacade

  @impl MutagenEx.Test.ExUnitFacade
  defdelegate configure(opts), to: ExUnit

  @impl MutagenEx.Test.ExUnitFacade
  defdelegate run(), to: ExUnit
end
