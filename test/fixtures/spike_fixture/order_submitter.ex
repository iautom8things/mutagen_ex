defmodule SpikeFixture.OrderSubmitter do
  @moduledoc """
  Plain module — no `use`, no `__using__/1`. Establishes the simplest
  case in the C1 spike: a pure-function module that should be cover-
  compatible, bytecode-mutable, and restorable without surprises.
  """

  @doc """
  Returns `:ok` for valid orders, `{:error, :invalid}` for non-positive
  totals. The C1 mutation flips this to always return `{:error, :mutated}`,
  which the fixture's own test catches as a failure.
  """
  def submit(%{total: total}) when total > 0, do: :ok
  def submit(%{total: _}), do: {:error, :invalid}

  @doc """
  A second pure function so coverage data has multiple lines to record.
  """
  def normalize(amount) when is_integer(amount), do: amount * 100
  def normalize(amount) when is_float(amount), do: round(amount * 100)
end
