defmodule Wrd25Bench.ArithDenseTest do
  use ExUnit.Case, async: false
  alias Wrd25Bench.ArithDense

  test "add/sub/mul/div_safe basics" do
    assert ArithDense.add(2, 3) == 5
    assert ArithDense.sub(10, 4) == 6
    assert ArithDense.mul(6, 7) == 42
    assert ArithDense.div_safe(20, 4) == 5.0
  end

  test "poly families" do
    assert ArithDense.poly1(0) == 15
    assert ArithDense.poly2(20) == 5
    assert ArithDense.poly3(1) == 24
    assert ArithDense.poly4(48) == 2.0
  end

  test "mix functions" do
    assert ArithDense.mix1(1, 2) == 2
    assert ArithDense.mix2(2, 3) == 11
    assert ArithDense.mix3(2, 3) == 11
    assert ArithDense.mix4(2, 3) == -1
  end

  test "chains" do
    assert ArithDense.chain1(0) == -2
    assert ArithDense.chain2(0) == 61
  end

  test "n-ary sums and prods" do
    assert ArithDense.sum_three(1, 2, 3) == 6
    assert ArithDense.diff_three(10, 2, 3) == 5
    assert ArithDense.prod_three(2, 3, 4) == 24
  end

  test "polynomial helpers" do
    assert ArithDense.linear(2, 3, 4) == 11
    assert ArithDense.quadratic(1, 2, 3, 4) == 27
    assert ArithDense.cubic(1, 0, 0, 0, 3) == 27
  end

  test "averages" do
    assert ArithDense.average2(2, 4) == 3.0
    assert ArithDense.average3(1, 2, 3) == 2.0
    assert ArithDense.average4(1, 2, 3, 4) == 2.5
  end
end
