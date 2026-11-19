defmodule HostSetupFixture.Application do
  use Application

  alias HostSetupFixture.Repo

  @impl Application
  def start(_type, _args) do
    with {:ok, supervisor} <- Supervisor.start_link([Repo], strategy: :one_for_one),
         {:ok, _} <- Repo.query("SELECT 1", [], timeout: 1_000),
         :ok <- check_alias() do
      {:ok, supervisor}
    end
  end

  defp check_alias do
    if Application.get_env(:host_setup_fixture, :alias_task) == :ready and
         Application.get_env(:host_setup_fixture, :alias_function) == :ready do
      :ok
    else
      {:error, :test_alias_did_not_prepare_app}
    end
  end
end
