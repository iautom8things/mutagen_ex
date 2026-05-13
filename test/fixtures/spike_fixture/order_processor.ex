defmodule SpikeFixture.OrderProcessor do
  @moduledoc """
  `use GenServer` fixture — the most common Elixir state-bearing pattern.
  C1 must prove that bytecode restore from cached AST round-trips this
  module without losing the callbacks `GenServer` injects.
  """

  use GenServer

  # Client API

  @doc """
  Pure helper exposed for mutation: the C1 spike mutates this to make
  the fixture's test fail, then restores to make it pass.
  """
  def double(n) when is_integer(n), do: n * 2

  # Server callbacks (not exercised by the spike test, but they must
  # survive bytecode restore because they're what `use GenServer` injects).

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call(:peek, _from, state), do: {:reply, state, state}
end
