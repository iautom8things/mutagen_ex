defmodule LaneFixture.Arith do
  @moduledoc """
  Arithmetic-heavy module for the lane fixture.

  Exercises the `:arith` mutator: every `+ - * /` is a candidate site. The
  tight test in `test/lane_fixture/arith_test.exs` pins both the values and
  the relationships between them so arith mutations (e.g. `+` → `-`) kill;
  the toothless test only checks that `add/2` returns an integer, so most
  mutations survive against it.
  """

  def add(a, b), do: a + b

  def sub(a, b), do: a - b

  def mul(a, b), do: a * b

  def div_safe(a, b) when b != 0, do: a / b
end
