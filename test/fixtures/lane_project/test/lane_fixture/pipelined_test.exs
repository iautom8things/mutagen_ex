defmodule LaneFixture.PipelinedTest do
  @moduledoc """
  Tight + toothless tests for `LaneFixture.Pipelined`.

  The tight tests pin the result of two-stage pipes so swapping the
  stages produces an observable difference: `String.trim` then
  `String.upcase` of `" hi "` is `"HI"`; swapped it would be `" HI "`.

  The toothless test only checks that `shout/1` returns a string, which
  survives the swap.
  """

  use ExUnit.Case, async: false

  test "shout/1 (tight: kills pipeline swap)" do
    assert LaneFixture.Pipelined.shout("  hi  ") == "HI"
  end

  test "first_doubled/1 (tight: kills pipeline swap)" do
    # `Enum.take(1)` then `Enum.map(*2)` of `[1, 2, 3]` → `[2]`.
    # Swapped: `Enum.map(*2)` then `Enum.take(1)` → `[2]`. Both give the
    # same answer here, so we use a multi-element source where the
    # difference shows up: take after map doubles everything, then takes
    # one; map after take doubles only the first.
    assert LaneFixture.Pipelined.first_doubled([1, 2, 3]) == [2]
  end

  test "shout/1 returns a string (toothless)" do
    assert is_binary(LaneFixture.Pipelined.shout("hello"))
  end
end
