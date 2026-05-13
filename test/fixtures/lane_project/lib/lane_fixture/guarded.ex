defmodule LaneFixture.Guarded do
  @moduledoc """
  Guard-clause module for the lane fixture.

  Exercises the `:guard_drop` mutator: each `when` clause on a function head
  is a candidate site. Dropping the guard widens the clause's match domain;
  the tight test calls the function with an argument the original guard
  would reject, asserting it raises `FunctionClauseError` — which the
  unguarded version would silently accept.
  """

  def only_positive(n) when is_integer(n) and n > 0, do: n

  def only_atoms(x) when is_atom(x), do: x
end
