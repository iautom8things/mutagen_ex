defmodule HostSetupFixture.DataCase do
  use ExUnit.CaseTemplate

  alias Ecto.Adapters.SQL.Sandbox
  alias HostSetupFixture.Repo

  setup tags do
    owner = Sandbox.start_owner!(Repo, shared: not tags.async)
    on_exit(fn -> Sandbox.stop_owner(owner) end)
    :ok
  end
end
