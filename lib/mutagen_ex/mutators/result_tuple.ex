defmodule MutagenEx.Mutators.ResultTuple do
  @moduledoc """
  Flips `{:ok, x}` and `{:error, x}` tagged tuples.

  Per `mutagen.mutators` catalog entry 8.

  Two-element tagged tuples in Elixir source parse as the 2-tuple literal
  `{:ok, x}` — i.e. an Elixir tuple value, NOT a `{form, meta, args}` AST
  node. We match on that 2-element tuple shape directly.

  ## Swap

  * `{:ok, x}` → `{:error, x}`
  * `{:error, x}` → `{:ok, x}`

  Fully symmetric: `mutate(mutate(node)) == node`.

  ## Validation

  * `:structurally_invalid` — not a `{:ok, _}` or `{:error, _}` 2-tuple.
  """

  @behaviour MutagenEx.Mutators

  @impl true
  def name, do: :result_tuple

  @impl true
  def match?({:ok, _}), do: true
  def match?({:error, _}), do: true
  def match?(_), do: false

  @impl true
  def mutate({:ok, value}), do: {:error, value}
  def mutate({:error, value}), do: {:ok, value}

  @impl true
  def validate({:ok, _}), do: :ok
  def validate({:error, _}), do: :ok
  def validate(_), do: {:skip, :structurally_invalid}
end
