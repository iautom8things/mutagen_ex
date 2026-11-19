defmodule MutagenEx.Mutators.WithSwap do
  @moduledoc """
  Reorders the first two `<-` clauses of a `with` expression.

  Per `mutagen.mutators` catalog entry 5.

  The two arrows must lead the `with`. Later clauses and the `do` and
  `else` blocks stay in place.

  Validation looks for a change in which failed match reaches the caller
  or `else` block. It checks these rules in order:

    * `:bound_var_used_before_binding` if the moved clause's expression,
      guard or pin references a binding introduced by the clause now after it.
    * `:insufficient_refutable_patterns` if either arrow always matches
      by syntax. This covers unguarded variables and wildcards, and literal
      patterns with a syntactically identical literal expression.
    * `:indistinguishable_failures` if both expressions are the same
      quoted literal or the same variable untouched by either pattern.
    * `:else_ignores_failure` if `else` consists of one `_ -> ...` arm.

  Other pairs with two potentially failing matches are kept. Guards and
  pins can fail. Calls are opaque, even when they have identical syntax.
  This heuristic can miss changes in side effects, exceptions, or variable
  rebinding caused by reordering. A kept pair can still return the same
  failure at runtime or rarely fail both checks on the same input.
  """

  @behaviour MutagenEx.Mutators

  alias MutagenEx.Mutators

  @impl Mutators
  def name, do: :with_swap

  @impl Mutators
  def match?({:with, _, [{:<-, _, [_, _]}, {:<-, _, [_, _]} | _]}), do: true

  def match?(_), do: false

  @impl Mutators
  def mutate({:with, meta, [{:<-, _, [_, _]} = first, {:<-, _, [_, _]} = second | rest]}) do
    {:with, meta, [second, first | rest]}
  end

  @impl Mutators
  def validate(
        {:with, _, [{:<-, _, [first, first_expr]}, {:<-, _, [second, second_expr]} | rest]}
      ) do
    {first_bindings, first_refs} = pattern_vars(first)
    {second_bindings, _second_refs} = pattern_vars(second)
    first_refs = MapSet.union(first_refs, free_vars(first_expr))

    cond do
      not MapSet.disjoint?(second_bindings, first_refs) ->
        {:skip, :bound_var_used_before_binding}

      always_matches?(first, first_expr) or always_matches?(second, second_expr) ->
        {:skip, :insufficient_refutable_patterns}

      same_value?(first_expr, second_expr, MapSet.union(first_bindings, second_bindings)) ->
        {:skip, :indistinguishable_failures}

      ignores_failure?(List.last(rest)) ->
        {:skip, :else_ignores_failure}

      true ->
        :ok
    end
  end

  def validate(_), do: {:skip, :structurally_invalid}

  defp always_matches?({name, _, context}, _expr) when is_atom(name) and is_atom(context) do
    not reserved_name?(name)
  end

  defp always_matches?(pattern, expr), do: same_literal?(pattern, expr)

  defp same_value?({name, _, context}, {name, _, context}, bindings)
       when is_atom(name) and is_atom(context) do
    not reserved_name?(name) and not MapSet.member?(bindings, name)
  end

  defp same_value?(left, right, _bindings), do: same_literal?(left, right)

  defp same_literal?(left, right) do
    Macro.quoted_literal?(left) and Mutators.normalize(left) === Mutators.normalize(right)
  end

  defp ignores_failure?(options) when is_list(options) do
    match?([{:->, _, [[{:_, _, context}], _]}] when is_atom(context), Keyword.get(options, :else))
  end

  defp ignores_failure?(_), do: false

  defp pattern_vars({:when, _, [pattern, guard]}) do
    {bindings, pins} = pattern_vars(pattern)
    {bindings, MapSet.union(pins, MapSet.difference(free_vars(guard), bindings))}
  end

  defp pattern_vars(pattern) do
    {unpinned, pins} =
      Macro.prewalk(pattern, MapSet.new(), fn
        {:^, _, [var]}, pins -> {nil, MapSet.union(pins, free_vars(var))}
        node, pins -> {node, pins}
      end)

    {free_vars(unpinned), pins}
  end

  # Approximate references without resolving scopes inside expressions.
  defp free_vars(expr) do
    {_ast, vars} =
      Macro.prewalk(expr, MapSet.new(), fn
        {name, _meta, ctx} = node, vars when is_atom(name) and is_atom(ctx) ->
          if name == :_ or reserved_name?(name),
            do: {node, vars},
            else: {node, MapSet.put(vars, name)}

        node, vars ->
          {node, vars}
      end)

    vars
  end

  @reserved [
    :__MODULE__,
    :__CALLER__,
    :__ENV__,
    :__DIR__,
    :__STACKTRACE__,
    :__aliases__,
    :__block__
  ]

  defp reserved_name?(name), do: name in @reserved
end
