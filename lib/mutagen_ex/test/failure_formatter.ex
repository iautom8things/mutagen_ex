defmodule MutagenEx.Test.FailureFormatter do
  @moduledoc false

  use GenServer

  def options(on_failure) do
    formatters = Application.get_env(:ex_unit, :formatters, [ExUnit.CLIFormatter])
    [formatters: formatters ++ [__MODULE__], mutagen_on_failure: on_failure]
  end

  @impl GenServer
  def init(opts) do
    # ExUnit starts its formatter supervisor from the process calling run/0.
    # The runner PID distinguishes overlapping suites in experimental mode.
    [_supervisor, runner | _] = Process.get(:"$ancestors")
    {:ok, {runner, Keyword.fetch!(opts, :mutagen_on_failure)}}
  end

  @impl GenServer
  def handle_cast({:test_finished, %{state: {status, _}} = test}, {runner, record} = state)
      when status in [:failed, :invalid] do
    record.(runner, test)
    {:noreply, state}
  end

  # ExUnit also counts previously passing tests as failures if module teardown fails.
  def handle_cast(
        {:module_finished, %{state: {:failed, _}, tests: tests}},
        {runner, record} = state
      ) do
    for %{state: nil} = test <- tests, do: record.(runner, test)
    {:noreply, state}
  end

  def handle_cast(_event, state), do: {:noreply, state}
end
