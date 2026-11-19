defmodule Wrd25Bench.ArithDense do
  @moduledoc """
  Arithmetic-dense module for the wrd25 bench fixture.

  Every `def` body packs multiple `+ - * /` operations so the `:arith`
  mutator surfaces a high site density per module — useful for
  exercising the batched prewalk in S4 and the helper lift in S1.
  """

  def add(a, b), do: a + b
  def sub(a, b), do: a - b
  def mul(a, b), do: a * b
  def div_safe(a, b) when b != 0, do: a / b

  def poly1(x), do: x + 1 + 2 + 3 + 4 + 5
  def poly2(x), do: x - 1 - 2 - 3 - 4 - 5
  def poly3(x), do: x * 2 * 3 * 4
  def poly4(x), do: x / 2 / 3 / 4

  def mix1(a, b), do: a + b * 2 - 3
  def mix2(a, b), do: a * b + 7 - 2
  def mix3(a, b), do: a * b * 3 + 1 - 4 * 2
  def mix4(a, b), do: a + b - a * b + 10 - 3

  def chain1(x), do: x + 1 + 2 - 3 + 4 - 5 + 6 - 7
  def chain2(x), do: x * 2 + 3 - 4 + 5 - 6 + 7 * 8

  def sum_three(a, b, c), do: a + b + c
  def diff_three(a, b, c), do: a - b - c
  def prod_three(a, b, c), do: a * b * c

  def linear(a, b, x), do: a * x + b
  def quadratic(a, b, c, x), do: a * x * x + b * x + c
  def cubic(a, b, c, d, x), do: a * x * x * x + b * x * x + c * x + d

  def average2(a, b), do: (a + b) / 2
  def average3(a, b, c), do: (a + b + c) / 3
  def average4(a, b, c, d), do: (a + b + c + d) / 4
end
