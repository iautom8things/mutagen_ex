defmodule MutagenEx.Mutators.WithSwap do
  @moduledoc """
  Reorders the first two `<-` clauses of a `with` expression.

  Per `mutagen.mutators` catalog entry 5.

  The two arrows must lead the `with`. Later clauses and the `do` and
  `else` blocks stay in place.

  Only independent clauses qualify for the failure-priority filters below.
  Clauses are dependent if their patterns bind a common name, either clause
  reads a name bound by the other, or either clause uses lexical introspection
  such as `binding()` or `__ENV__`.

  The node does not contain the enclosing bindings. To preserve the existing
  RHS dependency check, a read in the moved-first expression of a name bound
  by the moved-second pattern returns `{:skip, :bound_var_used_before_binding}`.
  An outer binding can make that swap valid. Reads in pins, guards and binary
  sizes can also use outer bindings, so those swaps are kept and the compiler
  reports a compile error if the binding is missing.

  For independent clauses, validation returns:

    * `:insufficient_refutable_patterns` if either arrow always matches
      by syntax: an unguarded variable or wildcard, or a literal pattern
      with an identical literal expression.
    * `:indistinguishable_failures` if both expressions are the same
      literal or read the same variable.
    * `:else_ignores_failure` if `else` consists of one `_ -> ...` arm.

  The reference scan handles anonymous-function parameters, matches in blocks,
  and quote boundaries. It approximates reads in other nested constructs and
  does not expand macros, so a macro can hide a read, binding, or side effect.
  Calls are opaque. The filters can miss swaps that only change side effects
  or exceptions, and kept swaps can still be equivalent.
  """

  @behaviour MutagenEx.Mutators

  alias MutagenEx.Mutators
  alias MutagenEx.Mutators.WithSwap.References

  @impl Mutators
  def name, do: :with_swap

  @impl Mutators
  def confidence, do: :low

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
    {first_bindings, first_pattern_reads} = References.pattern(first)
    {second_bindings, second_pattern_reads} = References.pattern(second)
    first_rhs_reads = References.expression(first_expr)
    second_rhs_reads = References.expression(second_expr)
    first_reads = MapSet.union(first_pattern_reads, first_rhs_reads)
    second_reads = MapSet.union(second_pattern_reads, second_rhs_reads)

    cond do
      not MapSet.disjoint?(second_bindings, first_rhs_reads) ->
        {:skip, :bound_var_used_before_binding}

      not MapSet.disjoint?(first_bindings, second_bindings) or
        not MapSet.disjoint?(first_bindings, second_reads) or
        not MapSet.disjoint?(second_bindings, first_reads) or
        :__ENV__ in first_reads or :__ENV__ in second_reads ->
        :ok

      always_matches?(first, first_expr) or always_matches?(second, second_expr) ->
        {:skip, :insufficient_refutable_patterns}

      same_value?(first_expr, second_expr) ->
        {:skip, :indistinguishable_failures}

      ignores_failure?(List.last(rest)) ->
        {:skip, :else_ignores_failure}

      true ->
        :ok
    end
  end

  def validate(_), do: {:skip, :structurally_invalid}

  defp always_matches?({:_, _, context}, _expr) when is_atom(context), do: true

  defp always_matches?(pattern, expr) do
    References.variable?(pattern) or same_literal?(pattern, expr)
  end

  defp same_value?({name, _, context} = left, {name, _, context})
       when is_atom(name) and is_atom(context) do
    References.variable?(left)
  end

  defp same_value?(left, right), do: same_literal?(left, right)

  defp same_literal?(left, right) do
    Macro.quoted_literal?(left) and Macro.quoted_literal?(right) and
      literal_key(left) === literal_key(right)
  end

  @literal_locations [
    :line,
    :column,
    :end_line,
    :end_column,
    :closing,
    :last,
    :end_of_expression,
    :newlines,
    :parens
  ]

  defp literal_key(ast) do
    Macro.postwalk(ast, fn
      {:%{}, meta, pairs} ->
        {:%{}, Keyword.drop(meta, @literal_locations), map_entries(pairs)}

      {form, meta, args} when is_list(meta) ->
        {form, Keyword.drop(meta, @literal_locations), args}

      value ->
        value
    end)
  end

  defp map_entries(pairs) do
    if Enum.all?(pairs, fn
         {key, _} when is_atom(key) or is_number(key) or is_binary(key) -> true
         _ -> false
       end) do
      Map.new(pairs)
    else
      pairs
    end
  end

  defp ignores_failure?(options) when is_list(options) do
    match?([{:->, _, [[{:_, _, context}], _]}] when is_atom(context), Keyword.get(options, :else))
  end

  defp ignores_failure?(_), do: false
end
