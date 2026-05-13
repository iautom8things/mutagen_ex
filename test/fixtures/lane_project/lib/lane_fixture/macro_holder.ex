defmodule LaneFixture.MacroHolder do
  @moduledoc """
  Module that contains a `use SomeModule` invocation.

  Exercises the `mutagen.mutation_pipeline.r8` state-drift warning path:
  any in-scope module whose source AST contains `use SomeModule` must
  produce a `mutation.state_drift_warning` entry naming the used module.

  We `use GenServer` because it's the canonical Elixir state-bearing
  pattern and matches what the C1 spike already proved restores cleanly.
  """

  use GenServer

  # A simple arithmetic helper gives the mutator catalog a site to chew
  # on inside the macro-holder module so the warning surface is exercised
  # alongside a real mutation result.
  def bump(n), do: n + 1

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call(:peek, _from, state), do: {:reply, state, state}
end
