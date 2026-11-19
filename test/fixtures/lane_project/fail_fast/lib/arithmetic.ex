defmodule FailFastFixture.Arithmetic do
  def first(a, b), do: a + b
  def second(a, b), do: a - b
  def third(a, b), do: a * b
  def loose(a, b), do: a / b
end
