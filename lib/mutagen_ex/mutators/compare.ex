defmodule MutagenEx.Mutators.Compare do
  @moduledoc """
  Swaps comparison operators: `== ↔ !=`, `< ↔ >=`, `> ↔ <=`.

  Per `mutagen.mutators` catalog entry 2. Each pair is symmetric:
  `mutate(mutate(node)) == node` for any matched node.
  """

  @behaviour MutagenEx.Mutators

  @swaps %{
    :== => :!=,
    :!= => :==,
    :< => :>=,
    :>= => :<,
    :> => :<=,
    :<= => :>
  }

  @ops Map.keys(@swaps)

  @impl true
  def name, do: :compare

  @impl true
  def match?({op, _meta, [_left, _right]}) when op in @ops, do: true
  def match?(_), do: false

  @impl true
  def mutate({op, meta, args}) when op in @ops do
    {Map.fetch!(@swaps, op), meta, args}
  end

  @impl true
  def validate({op, _meta, [_left, _right]}) when op in @ops, do: :ok
  def validate(_), do: {:skip, :structurally_invalid}
end
