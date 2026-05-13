defmodule LaneFixture.Pipelined do
  @moduledoc """
  Pipeline-heavy module for the lane fixture.

  Exercises the `:pipeline` mutator: any two-stage `|>` chain is a
  candidate. The tight test asserts on values that change when the two
  pipe stages are reordered.
  """

  def shout(s) do
    s
    |> String.trim()
    |> String.upcase()
  end

  def first_doubled(list) do
    list
    |> Enum.take(1)
    |> Enum.map(fn x -> x * 2 end)
  end
end
