defmodule Wrd25Bench.MixedB do
  @moduledoc """
  App-shaped mixed-density module 2 for the wrd25 bench fixture.

  Complements MixedA: more list/collection-shaped work, a few case
  dispatches over tags, and arithmetic in folds.
  """

  def sum_squares(xs), do: Enum.reduce(xs, 0, fn x, acc -> acc + x * x end)

  def sum_positive(xs) do
    Enum.reduce(xs, 0, fn x, acc -> if x > 0, do: acc + x, else: acc end)
  end

  def count_truthy(xs) do
    Enum.reduce(xs, 0, fn x, acc -> if x, do: acc + 1, else: acc end)
  end

  def parse_result(t) do
    case t do
      {:ok, n} when is_integer(n) and n > 0 -> {:ok, n * 2}
      {:ok, n} when is_integer(n) -> {:ok, n + 0}
      {:ok, _other} -> {:error, :bad_value}
      {:error, _reason} = err -> err
      :none -> {:error, :missing}
      _ -> {:error, :unknown}
    end
  end

  def stable_average(xs) when length(xs) > 0 do
    total = Enum.reduce(xs, 0, fn x, acc -> acc + x end)
    total / length(xs)
  end

  def threshold_split(xs, t) do
    {below, above} =
      Enum.reduce(xs, {[], []}, fn x, {b, a} ->
        if x < t, do: {[x | b], a}, else: {b, [x | a]}
      end)

    {Enum.reverse(below), Enum.reverse(above)}
  end

  def grade(score) do
    cond do
      score >= 90 -> :a
      score >= 80 -> :b
      score >= 70 -> :c
      score >= 60 -> :d
      true -> :f
    end
  end

  def vector_dot([], []), do: 0
  def vector_dot([h1 | t1], [h2 | t2]), do: h1 * h2 + vector_dot(t1, t2)

  def vector_add([], []), do: []
  def vector_add([h1 | t1], [h2 | t2]), do: [h1 + h2 | vector_add(t1, t2)]

  def vector_scale([], _), do: []
  def vector_scale([h | t], k), do: [h * k | vector_scale(t, k)]
end
