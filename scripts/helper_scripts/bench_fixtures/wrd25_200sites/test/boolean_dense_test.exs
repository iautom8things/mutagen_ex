defmodule Wrd25Bench.BooleanDenseTest do
  use ExUnit.Case, async: false
  alias Wrd25Bench.BooleanDense

  test "binary connectives" do
    assert BooleanDense.both(true, true)
    refute BooleanDense.both(true, false)
    assert BooleanDense.either(false, true)
    refute BooleanDense.either(false, false)
    assert BooleanDense.neither(false)
    refute BooleanDense.neither(true)
  end

  test "three-arg connectives" do
    assert BooleanDense.all_three(true, true, true)
    refute BooleanDense.all_three(true, false, true)
    assert BooleanDense.any_three(false, false, true)
    refute BooleanDense.any_three(false, false, false)
  end

  test "mixed precedence" do
    assert BooleanDense.mixed1(true, false, true)
    refute BooleanDense.mixed1(false, true, false)
    assert BooleanDense.mixed2(true, false, true)
    assert BooleanDense.mixed3(true, false, true, true)
    assert BooleanDense.mixed4(true, false, false, true)
  end

  test "short-circuit operators" do
    assert BooleanDense.short1(1, 2) == 2
    assert BooleanDense.short2(nil, 5) == 5
    assert BooleanDense.short3(1, 2, 3) == 2
    assert BooleanDense.short4(nil, 2, 3) == 3
    assert BooleanDense.short5(1, 2, 3, 4) == 4
    assert BooleanDense.short6(nil, nil, nil, 4) == 4
  end

  test "negation" do
    refute BooleanDense.negated(true, true)
    assert BooleanDense.negated(true, false)
    refute BooleanDense.negated_or(true, false)
    assert BooleanDense.negated_or(false, false)
  end

  test "chains" do
    assert BooleanDense.chain_and(true, true, true, true, true)
    refute BooleanDense.chain_and(true, false, true, true, true)
    assert BooleanDense.chain_or(false, false, false, false, true)
    refute BooleanDense.chain_or(false, false, false, false, false)
  end

  test "derived ops" do
    assert BooleanDense.implies(false, false)
    assert BooleanDense.implies(true, true)
    refute BooleanDense.implies(true, false)
    assert BooleanDense.xor(true, false)
    refute BooleanDense.xor(true, true)
    refute BooleanDense.xor(false, false)
  end

  test "truthiness" do
    assert BooleanDense.is_truthy(1)
    refute BooleanDense.is_truthy(nil)
    refute BooleanDense.is_falsy(1)
    assert BooleanDense.is_falsy(nil)
  end
end
