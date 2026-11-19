defmodule LaneFixture.DuplicateLiterals do
  def triple(x), do: {x, 1, 1}
  def opts, do: [log: true, retry: true]

  def clause(:first, x), do: x + 1
  def between(x), do: x + 1
  def clause(:last, x), do: x + 1
end
