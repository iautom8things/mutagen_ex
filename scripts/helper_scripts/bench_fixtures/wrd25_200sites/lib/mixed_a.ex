defmodule Wrd25Bench.MixedA do
  @moduledoc """
  App-shaped mixed-density module 1 for the wrd25 bench fixture.

  Representative of typical app code: a mix of arithmetic, boolean
  guards, simple case dispatch, and a couple of pipelines. Less dense
  than the `*_dense` modules but more realistic.
  """

  def compute_total(items) do
    Enum.reduce(items, 0, fn item, acc -> acc + item end)
  end

  def positive?(n), do: n > 0 and n != 0

  def in_range?(n, lo, hi), do: n >= lo and n <= hi

  def clamp(n, lo, hi) do
    cond do
      n < lo -> lo
      n > hi -> hi
      true -> n
    end
  end

  def discounted_price(price, pct) when pct >= 0 and pct <= 100 do
    price - price * pct / 100
  end

  def safe_div(a, b), do: if(b == 0, do: 0, else: a / b)

  def categorise(x) do
    case x do
      x when is_integer(x) and x > 0 -> :positive_int
      x when is_integer(x) and x < 0 -> :negative_int
      0 -> :zero
      x when is_float(x) -> :float
      x when is_binary(x) -> :string
      _ -> :other
    end
  end

  def compound_interest(p, r, n) do
    p * :math.pow(1 + r / 100, n)
  end

  def is_even?(n), do: rem(n, 2) == 0
  def is_odd?(n), do: rem(n, 2) != 0

  def fizzbuzz(n) do
    cond do
      rem(n, 15) == 0 -> "FizzBuzz"
      rem(n, 3) == 0 -> "Fizz"
      rem(n, 5) == 0 -> "Buzz"
      true -> Integer.to_string(n)
    end
  end
end
