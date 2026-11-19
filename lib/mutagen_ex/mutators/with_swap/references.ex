defmodule MutagenEx.Mutators.WithSwap.References do
  @moduledoc false

  @pseudo_variables [:_, :__MODULE__, :__CALLER__, :__ENV__, :__DIR__, :__STACKTRACE__]

  def variable?({name, _, context}) when is_atom(name) and is_atom(context) do
    name not in @pseudo_variables
  end

  def variable?(_), do: false

  def expression(ast), do: reads(ast, MapSet.new())

  def pattern({:when, _, [pattern, guard]}) do
    {bindings, refs} = pattern(pattern)
    {bindings, MapSet.union(refs, reads(guard, bindings))}
  end

  def pattern({:^, _, [operand]}), do: {MapSet.new(), expression(operand)}

  def pattern({:<<>>, _, segments}) do
    Enum.reduce(segments, {MapSet.new(), MapSet.new()}, fn
      {:"::", _, [segment, modifiers]}, {bindings, refs} ->
        merge_patterns(
          pattern(segment),
          {bindings, MapSet.union(refs, size_reads(modifiers, bindings))}
        )

      segment, acc ->
        merge_patterns(pattern(segment), acc)
    end)
  end

  def pattern(ast) do
    case variable?(ast) do
      true ->
        {MapSet.new([elem(ast, 0)]), MapSet.new()}

      false ->
        Enum.reduce(children(ast), {MapSet.new(), MapSet.new()}, &merge_patterns(pattern(&1), &2))
    end
  end

  defp merge_patterns({left_bindings, left_refs}, {right_bindings, right_refs}) do
    {MapSet.union(left_bindings, right_bindings), MapSet.union(left_refs, right_refs)}
  end

  defp size_reads({:size, _, [{:^, _, [operand]}]}, _locals), do: expression(operand)
  defp size_reads({:size, _, [operand]}, locals), do: reads(operand, locals)
  defp size_reads({:*, _, [size, _unit]}, locals), do: reads(size, locals)

  defp size_reads({:-, _, [left, right]}, locals) do
    MapSet.union(size_reads(left, locals), size_reads(right, locals))
  end

  defp size_reads(_, _locals), do: MapSet.new()

  defp reads(ast, locals) do
    {_locals, refs} = read(ast, {locals, MapSet.new()})
    refs
  end

  defp read({:__block__, _, expressions}, state) when is_list(expressions),
    do: Enum.reduce(expressions, state, &read/2)

  defp read({:=, _, [pattern, rhs]}, state) do
    {locals, refs} = read(rhs, state)
    {bindings, pattern_refs} = pattern(pattern)
    {MapSet.union(locals, bindings), add_reads(refs, pattern_refs, locals)}
  end

  defp read({:fn, _, clauses}, {locals, refs}) do
    {locals, Enum.reduce(clauses, refs, &read_fn_clause(&1, locals, &2))}
  end

  defp read({:quote, _, arguments}, {locals, refs}) when is_list(arguments) do
    if Enum.all?(arguments, &Keyword.keyword?/1) do
      {body, options} = arguments |> Enum.concat() |> Keyword.pop(:do)
      refs = read_children(options, locals, refs)

      unquote? = Keyword.get(options, :unquote, not Keyword.has_key?(options, :bind_quoted))
      {locals, if(unquote? == false, do: refs, else: read_unquotes(body, locals, refs))}
    else
      {locals, read_children(arguments, locals, refs)}
    end
  end

  defp read({:__ENV__, _, context}, {locals, refs}) when is_atom(context) do
    {locals, MapSet.put(refs, :__ENV__)}
  end

  defp read({:binding, _, args}, {locals, refs}) when is_list(args) do
    # Both forms of introspection use the same marker.
    {locals, read_children(args, locals, MapSet.put(refs, :__ENV__))}
  end

  defp read({{:., _, [receiver, :binding]}, _, args} = ast, {locals, refs}) do
    case receiver do
      Kernel ->
        read({:binding, [], args}, {locals, refs})

      {:__aliases__, _, parts} when parts in [[:Kernel], [:"Elixir", :Kernel]] ->
        read({:binding, [], args}, {locals, refs})

      _ ->
        {locals, read_children(children(ast), locals, refs)}
    end
  end

  defp read(ast, {locals, refs}) do
    if variable?(ast) do
      name = elem(ast, 0)
      {locals, if(MapSet.member?(locals, name), do: refs, else: MapSet.put(refs, name))}
    else
      {locals, read_children(children(ast), locals, refs)}
    end
  end

  defp read_fn_clause({:->, _, [parameters, body]}, locals, refs) do
    {parameters, guard} = split_guard(parameters)
    {bindings, pattern_refs} = pattern(parameters)
    inner_locals = MapSet.union(locals, bindings)
    refs = add_reads(refs, pattern_refs, locals)
    refs = MapSet.union(refs, reads(guard, inner_locals))
    MapSet.union(refs, reads(body, inner_locals))
  end

  defp split_guard([{:when, _, arguments}]) when length(arguments) >= 2 do
    {guard, parameters} = List.pop_at(arguments, -1)
    {parameters, guard}
  end

  defp split_guard(parameters), do: {parameters, nil}

  defp read_unquotes({:quote, _, _}, _locals, refs), do: refs

  defp read_unquotes({form, _, [expr]}, locals, refs)
       when form in [:unquote, :unquote_splicing] do
    MapSet.union(refs, reads(expr, locals))
  end

  defp read_unquotes(ast, locals, refs) do
    Enum.reduce(children(ast), refs, &read_unquotes(&1, locals, &2))
  end

  defp add_reads(refs, new_refs, locals),
    do: MapSet.union(refs, MapSet.difference(new_refs, locals))

  # Outside explicit matches, blocks and fn arms, visit children without
  # assuming their bindings flow to each other.
  defp read_children(children, locals, refs) do
    Enum.reduce(children, refs, fn child, acc ->
      {_child_locals, refs} = read(child, {locals, acc})
      refs
    end)
  end

  defp children({form, _, args}) when is_list(args), do: [form | args]
  defp children({left, right}), do: [left, right]
  defp children(list) when is_list(list), do: list
  defp children(_), do: []
end
