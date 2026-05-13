defmodule LaneFixture.ResultTuples do
  @moduledoc """
  Result-tuple module for the lane fixture.

  Exercises the `:result_tuple` mutator: every `{:ok, _}` and `{:error, _}`
  tagged 2-tuple is a candidate site. The tight test asserts the exact
  tag, so flipping `{:ok, _}` to `{:error, _}` (or vice versa) kills.
  """

  def fetch(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, :not_found}
    end
  end

  def safe_div(_a, 0), do: {:error, :division_by_zero}
  def safe_div(a, b), do: {:ok, a / b}
end
