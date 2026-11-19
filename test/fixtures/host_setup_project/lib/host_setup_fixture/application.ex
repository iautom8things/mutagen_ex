defmodule HostSetupFixture.Application do
  use Application

  alias HostSetupFixture.Repo

  @impl Application
  def start(_type, _args) do
    with {:ok, supervisor} <-
           Supervisor.start_link([Repo, HostSetupFixture.Output], strategy: :one_for_one),
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

defmodule HostSetupFixture.Output do
  use GenServer

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl GenServer
  def init(:ok), do: {:ok, :ok}

  @impl GenServer
  def handle_call({:write, text}, _from, state) do
    IO.puts(text)
    :io.put_chars(:user, [text, ?\n])
    {:reply, :ok, state}
  end
end
