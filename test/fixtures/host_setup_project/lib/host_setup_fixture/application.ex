defmodule HostSetupFixture.Application do
  use Application

  alias HostSetupFixture.Repo

  @impl Application
  def start(_type, _args) do
    with {:ok, supervisor} <- Supervisor.start_link([Repo], strategy: :one_for_one),
         {:ok, _} <- Repo.query("SELECT 1", [], timeout: 1_000) do
      {:ok, supervisor}
    end
  end
end
