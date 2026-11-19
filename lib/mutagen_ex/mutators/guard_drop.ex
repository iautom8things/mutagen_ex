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

  Remove the `:when` wrapper, leaving only the head/pattern. Nested guards
  (`x when a when b`) parse as one `:when` inside another, so each level
  is its own site.

  A multi-parameter anonymous function clause keeps every parameter in one
  node: `fn a, b when a > b -> a end` has `{:when, _, [a, b, guard]}`.
  Replacing that node cannot drop the guard without dropping parameters,
  so `mutate/1` returns it unchanged.

  ## Validation

  `validate/1` receives the result of `mutate/1`, like every other
  mutator. Any head or pattern is `:ok`. A multi-parameter `:when` node
  is `:structurally_invalid`, because `mutate/1` could not drop its guard.
  """

  @behaviour MutagenEx.Mutators

  @impl true
  def name, do: :guard_drop

  @impl MutagenEx.Mutators
  def confidence, do: :low

  @impl true
  def match?({:when, _meta, [_head, _guard]}), do: true
  def match?({:when, _meta, args}) when is_list(args) and length(args) >= 2, do: true
  def match?(_), do: false

  @impl true
  def mutate({:when, _meta, [head, _guard]}), do: head
  def mutate({:when, _meta, args} = node) when is_list(args) and length(args) > 2, do: node

  @impl true
  def validate({:when, _meta, [_, _, _ | _]}), do: {:skip, :structurally_invalid}
  def validate(_head_or_pattern), do: :ok
end
