defmodule MutagenEx.Mutators.WithSwap do
  @moduledoc """
  Reorders the first two `<-` clauses of a `with` expression.

  Per `mutagen.mutators` catalog entry 5.

  The two arrows must lead the `with`. Later clauses and the `do` and
  `else` blocks stay in place.

  Only independent clauses qualify for the failure-priority filters below.
  Treat the clauses as dependent if a name bound by either pattern appears
  anywhere in the other clause, or either clause uses lexical introspection
  such as `binding()`, `dbg()` or `__ENV__`.

  For the existing use-before-bind check, a variable-shaped name in the
  moved-first RHS that the moved-second pattern binds returns
  `{:skip, :bound_var_used_before_binding}`. This name scan ignores module
  attributes and binary modifiers. It can skip valid swaps when an outer
  binding supplies the name or the occurrence is local to a nested
  `fn`, case, for, receive, rescue, with, `match?`, match or destructure,
  or just quoted data. The compiler resolves dependencies in pins, guards
  and binary sizes when the swap is kept.

  For independent clauses, validation returns:

    * `:insufficient_refutable_patterns` if either arrow always matches
      by syntax: an unguarded variable or wildcard, or a literal pattern
      with an identical literal expression.
    * `:indistinguishable_failures` if both expressions are the same
      literal or read the same variable.
    * `:else_ignores_failure` if `else` consists of one `_ -> ...` arm.

  Unexpanded macros can hide reads, bindings and effects. The filters can
  miss swaps that only change side effects or exceptions, and kept swaps
  can still be equivalent.
  """

  @behaviour MutagenEx.Mutators

  alias MutagenEx.Mutators
  @pseudo_variables [:_, :__MODULE__, :__CALLER__, :__ENV__, :__DIR__, :__STACKTRACE__]

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
        {:with, _,
         [
           {:<-, _, [first, first_expr]} = first_clause,
           {:<-, _, [second, second_expr]} = second_clause | rest
         ]}
      ) do
    second_bindings = names(second, :bindings)

    cond do
      not MapSet.disjoint?(second_bindings, names(first_expr, :rhs)) ->
        {:skip, :bound_var_used_before_binding}

      dependent?(first_clause, second_clause, names(first, :bindings), second_bindings) ->
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

  defp dependent?(first, second, first_bindings, second_bindings) do
    first_names = names(first, :clause)
    second_names = names(second, :clause)

    :__ENV__ in first_names or :__ENV__ in second_names or
      not MapSet.disjoint?(first_bindings, second_names) or
      not MapSet.disjoint?(second_bindings, first_names)
  end

  defp names(ast, mode) do
    {_, names} =
      Macro.prewalk(ast, MapSet.new(), fn
        {:@, _, _}, names ->
          {nil, names}

        {:when, _, [pattern, _]}, names when mode == :bindings ->
          {[pattern], names}

        {:^, _, _}, names when mode == :bindings ->
          {nil, names}

        {:"::", _, [value, _]}, names when mode != :clause ->
          {[value], names}

        {name, _, context} = node, names
        when is_atom(name) and is_atom(context) and name not in @pseudo_variables ->
          {node, MapSet.put(names, name)}

        node, names when mode == :clause ->
          if introspects?(node), do: {node, MapSet.put(names, :__ENV__)}, else: {node, names}

        node, names ->
          {node, names}
      end)

    names
  end

  defp introspects?({:__ENV__, _, context}) when is_atom(context), do: true
  defp introspects?({:binding, _, args}) when is_list(args), do: true
  defp introspects?({:dbg, _, []}), do: true

  defp introspects?({{:., _, [kernel, name]}, _, args}) do
    case kernel do
      Kernel ->
        introspects?({name, [], args})

      {:__aliases__, _, parts} when parts in [[:Kernel], [:"Elixir", :Kernel]] ->
        introspects?({name, [], args})

      _ ->
        false
    end
  end

  defp introspects?(_), do: false

  defp always_matches?({:_, _, context}, _expr) when is_atom(context), do: true

  defp always_matches?(pattern, expr) do
    variable?(pattern) or same_literal?(pattern, expr)
  end

  defp same_value?({name, _, context} = left, {name, _, context})
       when is_atom(name) and is_atom(context) do
    variable?(left)
  end

  defp same_value?(left, right), do: same_literal?(left, right)

  defp variable?({name, _, context}) when is_atom(name) and is_atom(context),
    do: name not in @pseudo_variables

  defp variable?(_), do: false

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
