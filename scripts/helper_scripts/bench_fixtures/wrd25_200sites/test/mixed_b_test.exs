defmodule Wrd25Bench.MixedBTest do
  use ExUnit.Case, async: false
  alias Wrd25Bench.MixedB

  test "sum_squares" do
    assert MixedB.sum_squares([1, 2, 3]) == 14
    assert MixedB.sum_squares([]) == 0
  end

  test "sum_positive" do
    assert MixedB.sum_positive([1, -2, 3, -4]) == 4
    assert MixedB.sum_positive([]) == 0
  end

  test "count_truthy" do
    assert MixedB.count_truthy([1, nil, false, 2, true]) == 3
    assert MixedB.count_truthy([]) == 0
  end

  test "parse_result" do
    assert MixedB.parse_result({:ok, 3}) == {:ok, 6}
    assert MixedB.parse_result({:ok, 0}) == {:ok, 0}
    assert MixedB.parse_result({:ok, "x"}) == {:error, :bad_value}
    assert MixedB.parse_result({:error, :boom}) == {:error, :boom}
    assert MixedB.parse_result(:none) == {:error, :missing}
    assert MixedB.parse_result(:weird) == {:error, :unknown}
  end

  test "stable_average" do
    assert MixedB.stable_average([1, 2, 3, 4]) == 2.5
  end

  test "threshold_split" do
    assert MixedB.threshold_split([1, 5, 2, 8, 3, 9], 5) == {[1, 2, 3], [5, 8, 9]}
  end

  test "grade" do
    assert MixedB.grade(95) == :a
    assert MixedB.grade(85) == :b
    assert MixedB.grade(75) == :c
    assert MixedB.grade(65) == :d
    assert MixedB.grade(50) == :f
  end

  test "vector ops" do
    assert MixedB.vector_dot([1, 2, 3], [4, 5, 6]) == 32
    assert MixedB.vector_add([1, 2, 3], [10, 20, 30]) == [11, 22, 33]
    assert MixedB.vector_scale([1, 2, 3], 2) == [2, 4, 6]
  end
end
