defmodule LaneFixture.MacroHolderTest do
  @moduledoc """
  Tight + toothless tests for `LaneFixture.MacroHolder`.

  The module is mainly here to exercise the `mutation.state_drift_warning`
  surface (`mutagen.mutation_pipeline.r8`) — its `use GenServer` line is
  the signal. The arithmetic helper `bump/1` gives the mutator catalog a
  site to chew on so the warning fires alongside a real mutation result.
  """

  use ExUnit.Case, async: false

  test "bump/1 increments by 1 (tight)" do
    assert LaneFixture.MacroHolder.bump(41) == 42
  end

  test "bump/1 returns an integer (toothless)" do
    assert is_integer(LaneFixture.MacroHolder.bump(0))
  end
end
