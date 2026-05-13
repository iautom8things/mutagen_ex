defmodule MutagenEx.Mutators.GuardDrop do
  @moduledoc """
  Drops the guard from a function clause head.

  Per `mutagen.mutators` catalog entry 10.

  ## AST shape

  `def f(x) when x > 0, do: x` parses (inside the def macro) with a clause
  head wrapped in `:when`:

      {:when, meta, [{:f, _, [x]}, {:>, _, [x, 0]}]}

  Anonymous functions and `case` clauses can also carry guards in the form
  `{:->, _, [[{:when, _, [pattern, guard]}], body]}`. We match the bare
  `:when` AST shape; the enumerator can find these wherever they appear.

  ## Drop

  Remove the `:when` wrapper, leaving only the head/pattern.

  ## Validation

  * `:structurally_invalid` — not a `:when` form, or has fewer than 2
    children (pattern + guard).
  """

  @behaviour MutagenEx.Mutators

  @impl true
  def name, do: :guard_drop

  @impl true
  def match?({:when, _meta, [_head, _guard]}), do: true
  def match?({:when, _meta, args}) when is_list(args) and length(args) >= 2, do: true
  def match?(_), do: false

  @impl true
  def mutate({:when, _meta, [head, _guard]}), do: head

  def mutate({:when, _meta, args}) when is_list(args) and length(args) >= 2 do
    # Multi-guard form: {:when, _, [pattern, g1, g2, ..., gN]}. Drop guards.
    hd(args)
  end

  @impl true
  def validate({:when, _meta, args}) when is_list(args) and length(args) >= 2, do: :ok
  def validate(_), do: {:skip, :structurally_invalid}
end
