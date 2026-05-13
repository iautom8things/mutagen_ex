defmodule LaneFixture.ResultTuplesTest do
  @moduledoc """
  Tight + toothless tests for `LaneFixture.ResultTuples`.

  The tight tests assert the exact tag of every returned tuple, so the
  `:result_tuple` mutator's flip (`{:ok, _}` ↔ `{:error, _}`) is killed
  by every assertion.

  The toothless test only checks that the result is a 2-tuple, which
  survives the tag flip.
  """

  use ExUnit.Case, async: false

  test "fetch/2 on present key (tight)" do
    assert LaneFixture.ResultTuples.fetch(%{a: 1}, :a) == {:ok, 1}
  end

  test "fetch/2 on missing key (tight)" do
    assert LaneFixture.ResultTuples.fetch(%{a: 1}, :missing) == {:error, :not_found}
  end

  test "safe_div/2 by zero (tight)" do
    assert LaneFixture.ResultTuples.safe_div(10, 0) == {:error, :division_by_zero}
  end

  test "safe_div/2 by nonzero (tight)" do
    assert LaneFixture.ResultTuples.safe_div(10, 2) == {:ok, 5.0}
  end

  test "fetch/2 returns a 2-tuple (toothless)" do
    result = LaneFixture.ResultTuples.fetch(%{x: 1}, :x)
    assert is_tuple(result) and tuple_size(result) == 2
  end
end
