defmodule LaneFixture.Decisions do
  @moduledoc """
  Decision-heavy module for the lane fixture.

  Exercises the `:compare`, `:boolean`, and `:literal` mutators. Every
  comparison (`<`, `>=`), every boolean operator (`and`, `or`), and every
  boolean / small-integer literal is a candidate site.

  The `case` head plus an `if` with an `else` branch also gives the
  `:case_drop` and `:else_removal` mutators material to bite on.
  """

  def positive?(n), do: n > 0

  def not_negative?(n), do: n >= 0

  def both?(a, b), do: a and b

  def either?(a, b), do: a or b

  def classify(n) do
    case n do
      0 -> :zero
      1 -> :one
      _ -> :other
    end
  end

  def signum(n) do
    if n > 0 do
      1
    else
      -1
    end
  end

  def is_one?(n), do: n == 1
end
