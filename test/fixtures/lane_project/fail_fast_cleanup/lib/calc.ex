defmodule FailFastCleanup.Calc do
  def add(a, b), do: a + b
  def check(x), do: Application.get_env(:fail_fast_cleanup, :strict) != true or x > 0
end
