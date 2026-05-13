defmodule MutagenEx.Mutators.Arith do
  @moduledoc """
  Swaps numeric binary operators: `+ ↔ -`, `* ↔ /`.

  Per `mutagen.mutators` catalog entry 1. Symmetric: `mutate(mutate(node)) ==
  node` (covered by the property test for `mutagen.mutators.r5`).
  """

  @behaviour MutagenEx.Mutators

  @impl true
  def name, do: :arith

  @impl true
  def match?({op, _meta, [_left, _right]}) when op in [:+, :-, :*, :/], do: true
  def match?(_), do: false

  @impl true
  def mutate({:+, meta, args}), do: {:-, meta, args}
  def mutate({:-, meta, args}), do: {:+, meta, args}
  def mutate({:*, meta, args}), do: {:/, meta, args}
  def mutate({:/, meta, args}), do: {:*, meta, args}

  @impl true
  def validate({op, _meta, [_left, _right]}) when op in [:+, :-, :*, :/], do: :ok
  def validate(_), do: {:skip, :structurally_invalid}
end
