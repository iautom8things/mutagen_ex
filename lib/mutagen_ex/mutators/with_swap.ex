defmodule MutagenEx.Mutators.WithSwap do
  @moduledoc """
  Reorders the first two `<-` clauses of a `with` expression.

  Per `mutagen.mutators` catalog entry 5.

  ## AST shape

  Elixir parses `with C1 <- E1, C2 <- E2, do: body` as

      {:with, meta, [c1_clause, c2_clause, [do: body]]}

  where each `cN_clause` is `{:<-, meta, [pattern, expression]}`. Plain
  expression clauses (no arrow, used as boolean filters) are also legal
  AST children but are not the swap target.

  ## Swap

  We swap the first two consecutive `<-` clauses (positions 0 and 1 of the
  clause list). Non-`<-` filters between them are not the catalog's
  responsibility in v1.

  ## Validation

  `validate/1` checks for the most common no-op / structural problems:

    * `:bound_var_used_before_binding` — when after the swap, the second
      clause's expression references a variable that the first clause's
      pattern (now in second position) used to bind. Covers scenario
      `mutagen.mutators.s2`.
    * `:structurally_invalid` — the swap is not actually a `with` node with
      two leading `<-` clauses.

  This is an over-approximation: real escape analysis would require name
  resolution across the file. The simple "free variable in second
  expression, bound by second clause's pattern" check catches the common
  case in s2 without false negatives on it.
  """

  @behaviour MutagenEx.Mutators

  @impl true
  def name, do: :with_swap

  @impl true
  def match?({:with, _meta, clauses}) when is_list(clauses) do
    case extract_arrow_pair(clauses) do
      {_first, _second, _rest} -> true
      :error -> false
    end
  end

  def match?(_), do: false

  @impl true
  def mutate({:with, meta, clauses}) do
    {first, second, rest_before_do} = extract_arrow_pair_strict(clauses)
    # rest_before_do is the keyword list `[do: ...]` (and possibly `:else`) at the tail.
    {:with, meta, [second, first | rest_before_do]}
  end

  @impl true
  def validate({:with, _meta, clauses}) when is_list(clauses) do
    case clauses do
      [
        {:<-, _, [_first_pattern, first_expr]},
        {:<-, _, [second_pattern, _second_expr]} | _rest
      ] ->
        # After the swap, the (newly) first clause's *expression* runs before
        # the (newly) second clause's *pattern* has bound its variables. If
        # any name appears free in the first expression AND is bound by the
        # second pattern, the swap moved the use-before-bind.
        bound_by_second = pattern_vars(second_pattern)
        free_in_first_expr = free_vars(first_expr)

        if MapSet.disjoint?(bound_by_second, free_in_first_expr) do
          :ok
        else
          {:skip, :bound_var_used_before_binding}
        end

      _ ->
        {:skip, :structurally_invalid}
    end
  end

  def validate(_), do: {:skip, :structurally_invalid}

  # --- helpers ---

  defp extract_arrow_pair(clauses) do
    case extract_arrow_pair_strict_safe(clauses) do
      {:ok, triple} -> triple
      :error -> :error
    end
  end

  defp extract_arrow_pair_strict(clauses) do
    {:ok, triple} = extract_arrow_pair_strict_safe(clauses)
    triple
  end

  defp extract_arrow_pair_strict_safe([
         {:<-, _, [_, _]} = first,
         {:<-, _, [_, _]} = second
         | rest
       ]) do
    {:ok, {first, second, rest}}
  end

  defp extract_arrow_pair_strict_safe(_), do: :error

  # Variables introduced by a pattern (`{:ok, a}` binds `a`, `_x` binds nothing).
  defp pattern_vars(pattern) do
    pattern
    |> collect_vars()
    |> Enum.reject(&underscore?/1)
    |> MapSet.new()
  end

  # Variables referenced (not pattern-bound) by an expression. Over-approximates
  # by treating every `{name, _, ctx}` where `name` is an atom and `args` is an
  # atom (i.e. a bare variable reference) as a free variable. Function calls
  # like `f()` have `args` as a list, not an atom — they are not treated as
  # variable references.
  defp free_vars(expr) do
    expr
    |> collect_vars()
    |> Enum.reject(&underscore?/1)
    |> MapSet.new()
  end

  defp collect_vars(ast) do
    {_ast, acc} =
      Macro.prewalk(ast, [], fn
        {name, _meta, ctx} = node, acc when is_atom(name) and is_atom(ctx) ->
          # Bare variable reference. Skip kernel pseudo-vars like `__MODULE__`.
          if reserved_name?(name) do
            {node, acc}
          else
            {node, [name | acc]}
          end

        node, acc ->
          {node, acc}
      end)

    acc
  end

  defp underscore?(name) do
    name == :_ or String.starts_with?(Atom.to_string(name), "_")
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
