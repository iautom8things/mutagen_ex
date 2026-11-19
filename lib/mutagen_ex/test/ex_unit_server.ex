defmodule MutagenEx.Test.ExUnitServer do
  @moduledoc """
  Default `MutagenEx.Test.ExUnitServerFacade` implementation — thin
  wrapper over `ExUnit.Server`.

  Tests swap a different module via the `:ex_unit_server` config key.
  """

  @behaviour MutagenEx.Test.ExUnitServerFacade

  @impl MutagenEx.Test.ExUnitServerFacade
  defdelegate add_module(module, cfg), to: ExUnit.Server

  @impl MutagenEx.Test.ExUnitServerFacade
  def discard_pending_modules do
    # A runner cancelled during startup can exit before it drains the server.
    ExUnit.Server.modules_loaded(false)
    discard_async_modules()
    ExUnit.Server.take_sync_modules()
    :ok
  end

  defp discard_async_modules do
    if ExUnit.Server.take_async_modules(100), do: discard_async_modules()
  end

  @doc false
  def register_cited_modules(_server, []), do: :ok

  def register_cited_modules(server, modules) do
    # Loading a new test file already queues its modules with their source options.
    :ok = server.discard_pending_modules()
    Enum.each(modules, fn {module, cfg} -> server.add_module(module, cfg) end)
  end
end
