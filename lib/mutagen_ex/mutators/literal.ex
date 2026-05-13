defmodule MutagenEx.Mutators.Literal do
  @moduledoc """
  Flips `true ↔ false` and swaps small integer literals: `0 ↔ 1`, `1 ↔ -1`.

  Per `mutagen.mutators` catalog entry 4.

  The boolean flip is fully symmetric.

  The integer rewrite is restricted to the literals `0`, `1`, and `-1` so
  the swap stays within "small integer" territory and so reversibility is
  well-defined:

    * `0 → 1`
    * `1 → 0`
    * `-1 → 1`

  Wider integers are intentionally out of scope: the catalog is closed in
  v1 (`mutagen.mutators.r7`), and adding configurable integer pools would
  cross that line.
  """

  @behaviour MutagenEx.Mutators

  @impl true
  def name, do: :literal

  @impl true
  def match?(true), do: true
  def match?(false), do: true
  def match?(0), do: true
  def match?(1), do: true
  def match?(-1), do: true
  def match?(_), do: false

  @impl true
  def mutate(true), do: false
  def mutate(false), do: true
  def mutate(0), do: 1
  def mutate(1), do: 0
  def mutate(-1), do: 1

  @impl true
  def validate(value) when is_boolean(value), do: :ok
  def validate(value) when is_integer(value), do: :ok
  def validate(_), do: {:skip, :structurally_invalid}
end
