defmodule Wrd25Bench.BooleanDense do
  @moduledoc """
  Boolean-dense module for the wrd25 bench fixture.

  Heavy `and / or / not / && / || / !` density so the `:boolean`
  mutator surfaces a high site count.
  """

  def both(a, b), do: a and b
  def either(a, b), do: a or b
  def neither(a), do: not a

  def all_three(a, b, c), do: a and b and c
  def any_three(a, b, c), do: a or b or c

  def mixed1(a, b, c), do: a and b or c
  def mixed2(a, b, c), do: a or b and c
  def mixed3(a, b, c, d), do: a and b or c and d
  def mixed4(a, b, c, d), do: (a or b) and (c or d)

  def short1(a, b), do: a && b
  def short2(a, b), do: a || b
  def short3(a, b, c), do: a && b || c
  def short4(a, b, c), do: a || b && c
  def short5(a, b, c, d), do: a && b && c && d
  def short6(a, b, c, d), do: a || b || c || d

  def negated(a, b), do: not (a and b)
  def negated_or(a, b), do: not (a or b)

  def chain_and(a, b, c, d, e), do: a and b and c and d and e
  def chain_or(a, b, c, d, e), do: a or b or c or d or e

  def implies(a, b), do: not a or b
  def xor(a, b), do: (a or b) and not (a and b)

  def is_truthy(x), do: !!x
  def is_falsy(x), do: !x
end
