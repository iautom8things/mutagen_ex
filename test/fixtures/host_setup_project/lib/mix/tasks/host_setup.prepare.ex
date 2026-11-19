defmodule Mix.Tasks.HostSetup.Prepare do
  use Mix.Task

  @impl Mix.Task
  def run([]), do: Application.put_env(:host_setup_fixture, :alias_task, :ready)
end
