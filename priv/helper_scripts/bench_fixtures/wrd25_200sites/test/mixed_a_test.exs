defmodule Wrd25Bench.MixedATest do
  use ExUnit.Case, async: false
  alias Wrd25Bench.MixedA

  test "compute_total" do
    assert MixedA.compute_total([1, 2, 3, 4]) == 10
    assert MixedA.compute_total([]) == 0
  end

  test "positive?" do
    assert MixedA.positive?(5)
    refute MixedA.positive?(0)
    refute MixedA.positive?(-3)
  end

  test "in_range?" do
    assert MixedA.in_range?(5, 1, 10)
    refute MixedA.in_range?(11, 1, 10)
    refute MixedA.in_range?(0, 1, 10)
    assert MixedA.in_range?(1, 1, 10)
    assert MixedA.in_range?(10, 1, 10)
  end

  test "clamp" do
    assert MixedA.clamp(5, 0, 10) == 5
    assert MixedA.clamp(-1, 0, 10) == 0
    assert MixedA.clamp(11, 0, 10) == 10
  end

  test "discounted_price" do
    assert MixedA.discounted_price(100, 10) == 90.0
    assert MixedA.discounted_price(50, 0) == 50.0
    assert MixedA.discounted_price(200, 50) == 100.0
  end

  test "safe_div" do
    assert MixedA.safe_div(10, 2) == 5.0
    assert MixedA.safe_div(10, 0) == 0
  end

  test "categorise" do
    assert MixedA.categorise(5) == :positive_int
    assert MixedA.categorise(-5) == :negative_int
    assert MixedA.categorise(0) == :zero
    assert MixedA.categorise(1.5) == :float
    assert MixedA.categorise("abc") == :string
    assert MixedA.categorise([]) == :other
  end

  test "compound_interest" do
    # principal 1000, rate 10%, 2 years -> 1000 * 1.21 = 1210
    assert_in_delta MixedA.compound_interest(1000, 10, 2), 1210.0, 0.001
  end

  test "is_even?/is_odd?" do
    assert MixedA.is_even?(4)
    refute MixedA.is_even?(5)
    refute MixedA.is_odd?(4)
    assert MixedA.is_odd?(5)
  end

  test "fizzbuzz" do
    assert MixedA.fizzbuzz(15) == "FizzBuzz"
    assert MixedA.fizzbuzz(9) == "Fizz"
    assert MixedA.fizzbuzz(10) == "Buzz"
    assert MixedA.fizzbuzz(7) == "7"
  end
end
