defmodule LaneFixture.StructHolder do
  @moduledoc """
  Module that defines a struct.

  Exercises the contract that struct definitions don't crash the mutation
  pipeline. There are no traditional "mutation sites" inside `defstruct`
  itself, but the module body holds enough other code (a builder + a
  predicate) that the catalog can produce sites against the surrounding
  functions while the struct definition survives every restore cycle.
  """

  defstruct [:name, :count]

  def new(name) when is_binary(name), do: %__MODULE__{name: name, count: 0}

  def empty?(%__MODULE__{count: c}), do: c == 0
end
