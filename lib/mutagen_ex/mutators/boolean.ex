defmodule MutagenEx.Mutators.Boolean do
  @moduledoc """
  Swaps boolean operators and drops boolean negations:
  `and ↔ or`, `&& ↔ ||`, `not x → x`, `!x → x`.

  Per `mutagen.mutators` catalog entry 3. The binary swaps are symmetric.
  The negation drops are NOT symmetric — once `not`/`!` is gone, applying
  `mutate/1` again does not restore it because `mutate/1` only knows how
  to drop a wrapper, not add one. The symmetric-swap property (r5) is
  therefore restricted to binary forms; negation drops are covered by
  unit tests instead.
  """

  @behaviour MutagenEx.Mutators

  @binary_swaps %{and: :or, or: :and, &&: :||, ||: :&&}
  @binary_ops Map.keys(@binary_swaps)

  @impl true
  def name, do: :boolean

  @impl true
  def match?({op, _meta, [_left, _right]}) when op in @binary_ops, do: true
  def match?({:not, _meta, [_operand]}), do: true
  def match?({:!, _meta, [_operand]}), do: true
  def match?(_), do: false

  @impl true
  def mutate({op, meta, args}) when op in @binary_ops do
    {Map.fetch!(@binary_swaps, op), meta, args}
  end

  def mutate({:not, _meta, [operand]}), do: operand
  def mutate({:!, _meta, [operand]}), do: operand

  @impl true
  def validate({op, _meta, [_left, _right]}) when op in @binary_ops, do: :ok

  def validate(other) when is_tuple(other) or is_atom(other) or is_number(other) or
                             is_binary(other) or is_list(other) do
    # Dropping `not`/`!` always leaves a syntactically valid expression: the
    # operand was already a well-formed boolean expression before negation.
    :ok
  end

  def validate(_), do: {:skip, :structurally_invalid}
end
