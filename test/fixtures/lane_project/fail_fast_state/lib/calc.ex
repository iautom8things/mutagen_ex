defmodule FailFastState.Calc do
  def add(a, b), do: a + b
  def size(x), do: if(x > 100, do: :big, else: :small)
end
