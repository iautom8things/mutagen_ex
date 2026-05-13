defmodule LaneFixture.InfiniteLooperTest do
  @moduledoc """
  Tight test for `LaneFixture.InfiniteLooper`.

  Calls `count_down/1` with a small positive integer. The unmutated
  function terminates because of the base case (`0 -> :done`). After
  `:case_drop` removes the last clause (the base case), the recursive
  clause matches every integer including 0, then recurses on -1, -2, …
  forever — the e2e test asserts the mutation classifies as `:timeout`.
  """

  use ExUnit.Case, async: false

  # The baseline run for this module must complete quickly — keep the
  # input small.
  test "count_down/1 terminates (tight: tests the base case)" do
    assert LaneFixture.InfiniteLooper.count_down(3) == :done
  end
end
