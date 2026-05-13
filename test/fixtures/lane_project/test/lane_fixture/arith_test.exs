defmodule LaneFixture.ArithTest do
  @moduledoc """
  Tight + toothless tests for `LaneFixture.Arith`.

  The tight tests assert specific values that change when any of the four
  arithmetic operators (`+`, `-`, `*`, `/`) is swapped. The toothless test
  only checks return-shape (integer-ness), so most arith mutations
  survive against it — a deliberate target so the e2e suite can observe
  both `:killed` and `:survived` outcomes on the same module.
  """

  use ExUnit.Case, async: false

  test "add/2 returns the exact sum (tight)" do
    assert LaneFixture.Arith.add(2, 3) == 5
  end

  test "sub/2 returns the exact difference (tight)" do
    assert LaneFixture.Arith.sub(10, 4) == 6
  end

  test "mul/2 returns the exact product (tight)" do
    assert LaneFixture.Arith.mul(6, 7) == 42
  end

  test "div_safe/2 returns the exact quotient (tight)" do
    assert LaneFixture.Arith.div_safe(20, 4) == 5.0
  end

  test "add/2 returns an integer (toothless)" do
    # This test passes whether the body is `a + b`, `a - b`, `a * b`, or
    # `a / b` — well, `/` returns float, but `+`/`-`/`*` all return
    # integer for integer args, so mutating `+` to `-` or `*` survives.
    result = LaneFixture.Arith.add(3, 4)
    assert is_number(result)
  end
end
