defmodule MutagenEx.Ast do
  @moduledoc """
  Canonical shared AST helpers for the mutagen pipeline.

  Resolves source module and definition names and extracts
  positions for the scope resolver, enumerator, and runner.

  Implements the behavioural contract in
  [`mutagen.ast`](https://github.com/iautom8things/mutagen_ex/blob/main/.spec/specs/ast.spec.md).

  ## Atom safety

  `find_module_body/2` accepts a `target_mod_str` (a string, NEVER an
  atom built from user input). Module matching is performed via string
  comparison: `Atom.to_string/1` of each AST-derived module atom is
  compared against `target_mod_str` (with the leading `"Elixir."`
  prefix stripped from the AST atom's string form). This preserves the
  atom-table-bound invariant from `mutagen.scope_resolution.r8`
  (mutagen-wrd.20) — no `String.to_atom/1` is ever applied to caller
  input.

  The previous donor `find_module_body/2` variants in
  `MutationEnumerator` and `MutationRunner` accepted a module **atom**
  and matched via `^target_mod`. Those donors only ever passed atoms
  that already came from the AST (via `ScopeResolver` results), so the
  atom-table-DOS contract was already satisfied at the call sites. The
  lifted contract switches the input type to `String.t()` to make the
  safety boundary explicit at the function signature itself — callers
  that hold an atom-typed module pass `Atom.to_string/1` of it (still
  safe because the atom came from the AST).
  """

  @typedoc "An Elixir Macro AST node."
  @type ast :: Macro.t()

  @doc """
  Convert an `:__aliases__` AST tuple or bare module atom to a module
  atom. Returns `nil` for any other shape.

  Total: never raises, throws, or exits. Per `mutagen.ast.r1`.

  ## Shapes accepted

    * `{:__aliases__, _meta, parts}` where every element of `parts` is
      an atom — returns `Module.concat(parts)`. Note: this calls
      `Module.concat/1`, which CAN create a new atom in the atom table
      (the materialized module atom). This is safe in mutagen's use
      because the parts list comes from AST already parsed from
      project source — never directly from caller input. Same trust
      boundary as the pre-`.25` donor implementations.

    * A bare module atom (e.g. `Foo.Bar`) — returned unchanged.

  ## Shapes that return `nil`

    * Aliases whose `parts` list contains a non-atom element (e.g.
      `{:__aliases__, _, [{:meta, _, _}, :Foo]}` — a dynamic alias).

    * Any other non-atom, non-alias input (integer, string, list,
      tuple of any other shape).
  """
  @spec alias_to_module(ast) :: module() | nil
  def alias_to_module({:__aliases__, _meta, parts}) when is_list(parts) do
    if Enum.all?(parts, &is_atom/1) do
      Module.concat(parts)
    else
      nil
    end
  end

  def alias_to_module(mod) when is_atom(mod), do: mod
  def alias_to_module(_), do: nil

  @doc """
  Locate the body AST for `defmodule <target> do ... end` inside `ast`.

  Returns `{:ok, body_ast}` if any `:defmodule` node in `ast` matches
  the supplied `target_mod_str` (a string). The match is performed via
  `Atom.to_string/1` of each AST-derived module atom, with the
  `"Elixir."` prefix stripped — so `"Foo.Bar"` matches
  `defmodule Foo.Bar do ... end` whose AST module atom is `Foo.Bar`.

  Returns `:not_found` if no matching `defmodule` exists.

  Total: never raises, throws, or exits. Per `mutagen.ast.r2`.

  ## Atom safety

  `target_mod_str` is a string. This function NEVER passes it through
  `String.to_atom/1`. Callers that hold a module atom (e.g. from a
  `%MutagenEx.ScopeResolver.Scope{}` record) should pass
  `Atom.to_string/1` of it — the atom came from the AST, so its string
  form round-trips through `==` correctly. See module doc for the
  atom-table-DOS context.

  Returns the first unquoted declaration in depth-first source order.
  Named protocols and statically resolvable implementations participate.
  """
  @spec find_module_body(ast, String.t()) :: {:ok, ast} | :not_found
  def find_module_body(ast, target_mod_str) when is_binary(target_mod_str) do
    Enum.find_value(module_blocks(ast), :not_found, fn {module, _node, body} ->
      if module_string_matches?(module, target_mod_str), do: {:ok, body}
    end)
  end

  @doc false
  def module_blocks(ast) do
    for {node, modules, body, _path} <- declarations(ast), module <- modules do
      {module, node, body}
    end
  end

  @doc false
  def module_index(ast) do
    Map.new(declarations(ast), fn {node, modules, body, path} ->
      {node, {modules, body, path}}
    end)
  end

  defp declarations(ast) do
    ast |> collect_modules(nil, %{}, []) |> Enum.reverse()
  end

  defp collect_modules({:quote, _, _}, _parent, _aliases, acc), do: acc

  defp collect_modules({:__block__, _, expressions}, parent, aliases, acc)
       when is_list(expressions) do
    {_, acc} =
      Enum.reduce(expressions, {aliases, acc}, fn expression, {aliases, acc} ->
        acc = collect_modules(expression, parent, aliases, acc)
        {extend_aliases(expression, parent, aliases), acc}
      end)

    acc
  end

  defp collect_modules({kind, _, [name | options]} = node, parent, aliases, acc)
       when kind in [:defmodule, :defprotocol, :defimpl] do
    case do_block(options) do
      {body, arg, index} ->
        modules = module_names(kind, name, options, parent, aliases)
        acc = [{node, modules, body, [{:arg, arg}, {:elem, index}, :right]} | acc]
        collect_modules(body, single_module(modules), aliases, acc)

      nil ->
        acc
    end
  end

  defp collect_modules(tuple, parent, aliases, acc) when is_tuple(tuple),
    do: collect_modules(Tuple.to_list(tuple), parent, aliases, acc)

  defp collect_modules([head | tail], parent, aliases, acc) do
    acc = collect_modules(head, parent, aliases, acc)
    collect_modules(tail, parent, aliases, acc)
  end

  defp collect_modules(_other, _parent, _aliases, acc), do: acc

  @doc false
  def single_module([module]), do: module
  def single_module(_), do: nil

  defp extend_aliases({kind, _, [{:__aliases__, _, [first | _]} | _]}, parent, aliases)
       when kind in [:defmodule, :defprotocol] and is_atom(first) and first != Elixir and
              not is_nil(parent) do
    Map.put(aliases, first, Module.concat(parent, first))
  end

  defp extend_aliases({:alias, _, [{{:., _, [prefix, :{}]}, _, names}]}, parent, aliases)
       when is_list(names) do
    case reference_module(prefix, parent, aliases) do
      nil ->
        aliases

      module ->
        Enum.reduce(names, aliases, fn
          {:__aliases__, _, parts} = name, aliases ->
            if Enum.all?(parts, &is_atom/1) do
              Map.put(aliases, alias_leaf(name), Module.concat([module | parts]))
            else
              aliases
            end

          _, aliases ->
            aliases
        end)
    end
  end

  defp extend_aliases({:alias, _, [name | options]}, parent, aliases) do
    leaf = options |> option(:as, name) |> alias_leaf()
    module = reference_module(name, parent, aliases)

    if leaf && module, do: Map.put(aliases, leaf, module), else: aliases
  end

  defp extend_aliases(_node, _parent, aliases), do: aliases

  defp alias_leaf({:__aliases__, _, parts}) when is_list(parts), do: List.last(parts)
  defp alias_leaf(_), do: nil

  defp do_block(options) do
    options
    |> Enum.with_index(1)
    |> Enum.find_value(fn
      {keywords, arg} when is_list(keywords) ->
        keywords
        |> Enum.with_index()
        |> Enum.find_value(fn
          {{:do, body}, index} -> {body, arg, index}
          _ -> nil
        end)

      _ ->
        nil
    end)
  end

  defp module_names(:defimpl, protocol, options, parent, aliases) do
    target = option(options, :for, parent)
    module = reference_module(protocol, parent, aliases)

    with true <- valid_module?(module),
         [_ | _] = types <-
           Enum.map(List.wrap(target), &reference_module(&1, parent, aliases)),
         true <- Enum.all?(types, &valid_module?/1) do
      Enum.map(types, &Module.concat(module, &1))
    else
      _ -> []
    end
  end

  defp module_names(_kind, name, _options, parent, _aliases) do
    module = declared_module(name, parent)
    if valid_module?(module), do: [module], else: []
  end

  defp option(options, key, default) do
    Enum.find_value(options, default, fn
      list when is_list(list) -> Keyword.get(list, key)
      _ -> nil
    end)
  end

  defp valid_module?(value), do: is_atom(value) and value not in [nil, true, false]

  defp reference_module({:__MODULE__, _, _}, parent, _aliases), do: parent

  defp reference_module({:__aliases__, _, [{:__MODULE__, _, _} | _]} = name, parent, _aliases),
    do: declared_module(name, parent)

  defp reference_module({:__aliases__, _, [Elixir | _]} = name, _parent, _aliases),
    do: alias_to_module(name)

  defp reference_module({:__aliases__, _, [first | rest]} = name, _parent, aliases) do
    case Map.fetch(aliases, first) do
      {:ok, module} ->
        if Enum.all?(rest, &is_atom/1), do: Module.concat([module | rest])

      :error ->
        alias_to_module(name)
    end
  end

  defp reference_module(name, _parent, _aliases), do: alias_to_module(name)

  @doc false
  def declared_module({:__aliases__, _, [Elixir | _]} = name, _parent),
    do: alias_to_module(name)

  def declared_module({:__aliases__, _, [{:__MODULE__, _, _} | parts]}, parent)
      when is_atom(parent) and not is_nil(parent) do
    if Enum.all?(parts, &is_atom/1), do: Module.concat([parent | parts])
  end

  def declared_module({:__aliases__, _, _} = name, parent) when not is_nil(parent) do
    case alias_to_module(name) do
      nil -> nil
      module -> Module.concat(parent, module)
    end
  end

  def declared_module(name, _parent), do: alias_to_module(name)

  @doc false
  def definition_head({kind, _, [head | _]})
      when kind in [:def, :defp, :defmacro, :defmacrop, :defguard, :defguardp],
      do: head

  def definition_head(_), do: nil

  @doc false
  def definition_signature(node), do: head_signature(definition_head(node))

  defp head_signature({:when, _, [head | _]}), do: head_signature(head)
  defp head_signature({:unquote, _, _}), do: nil

  defp head_signature({name, _, args}) when is_atom(name) and is_list(args),
    do: {name, length(args)}

  defp head_signature({name, _, nil}) when is_atom(name), do: {name, 0}
  defp head_signature(_), do: nil

  # Compare an AST-derived module atom against a `target_mod_str` per
  # the contract in the @doc. The AST atom's `Atom.to_string/1` form is
  # `"Elixir.Foo.Bar"` (with the `Elixir.` prefix); the caller-supplied
  # target is generally the bare `"Foo.Bar"`. We strip the prefix from
  # the AST side so callers can pass either form.
  defp module_string_matches?(mod_atom, target_mod_str) do
    mod_str = Atom.to_string(mod_atom)
    stripped = strip_elixir_prefix(mod_str)
    mod_str == target_mod_str or stripped == target_mod_str
  end

  defp strip_elixir_prefix("Elixir." <> rest), do: rest
  defp strip_elixir_prefix(other), do: other

  @doc """
  Extract the `:line` value from a Macro AST node's metadata.

  Returns the integer line number if the node is a 3-tuple `{form,
  meta, args}` where `meta` is a keyword list carrying `:line`.
  Returns `nil` for any other shape (bare literals, 2-tuples, lists,
  or 3-tuples whose meta lacks `:line`).

  Total: never raises, throws, or exits. Per `mutagen.ast.r3`.
  """
  @spec node_line(ast) :: integer() | nil
  def node_line({_form, meta, _args}) when is_list(meta), do: Keyword.get(meta, :line)
  def node_line(_), do: nil
end
