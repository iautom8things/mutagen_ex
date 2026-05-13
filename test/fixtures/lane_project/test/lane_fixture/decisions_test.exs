defmodule LaneFixture.DecisionsTest do
  @moduledoc """
  Tight + toothless tests for `LaneFixture.Decisions`.

  The tight tests pin specific boundary values around `0` and `1` so that
  flipping `>` to `<=` or `>=` to `<` produces an observable failure.
  The literal flips (`true ↔ false`, `0 ↔ 1`, `1 ↔ 0`) and the boolean
  swaps (`and ↔ or`) are each pinned by a tight assertion.

  The toothless test only checks that `classify/1` returns one of the
  known atoms — `case_drop` against the last clause produces a missing
  match for the `_` catch-all, which the runtime raises — but `case_drop`
  swallowing the `1 -> :one` clause is silently masked by the `_ -> :other`
  catch-all unless the test asserts on `:one` specifically.
  """

  use ExUnit.Case, async: false

  test "positive?/1 (tight boundary)" do
    assert LaneFixture.Decisions.positive?(1) == true
    assert LaneFixture.Decisions.positive?(0) == false
    assert LaneFixture.Decisions.positive?(-1) == false
  end

  test "not_negative?/1 (tight boundary)" do
    assert LaneFixture.Decisions.not_negative?(0) == true
    assert LaneFixture.Decisions.not_negative?(-1) == false
  end

  test "both?/2 truth table (tight)" do
    assert LaneFixture.Decisions.both?(true, true) == true
    assert LaneFixture.Decisions.both?(true, false) == false
    assert LaneFixture.Decisions.both?(false, true) == false
  end

  test "either?/2 truth table (tight)" do
    assert LaneFixture.Decisions.either?(true, false) == true
    assert LaneFixture.Decisions.either?(false, false) == false
  end

  test "classify/1 on every clause (tight: kills case_drop on last clause)" do
    assert LaneFixture.Decisions.classify(0) == :zero
    assert LaneFixture.Decisions.classify(1) == :one
    assert LaneFixture.Decisions.classify(99) == :other
  end

  test "signum/1 (tight)" do
    assert LaneFixture.Decisions.signum(5) == 1
    assert LaneFixture.Decisions.signum(-5) == -1
  end

  test "is_one?/1 (tight: kills the `== / !=` swap)" do
    assert LaneFixture.Decisions.is_one?(1) == true
    assert LaneFixture.Decisions.is_one?(2) == false
  end

  test "classify/1 returns an atom (toothless)" do
    # This passes for every classify mutation that still returns SOME
    # atom — e.g. swapping `:zero` for `:one` would still pass.
    assert is_atom(LaneFixture.Decisions.classify(0))
  end
end
