defmodule MutagenEx.Ast do
  @moduledoc """
  Canonical shared AST helpers for the mutagen pipeline.

  Owns the three helpers that were previously duplicated across
  `MutagenEx.ScopeResolver`, `MutagenEx.MutationEnumerator`, and
  `MutagenEx.MutationRunner`:

    * `alias_to_module/1`
    * `find_module_body/2`
    * `node_line/1`

  Implements the behavioural contract in
  [`mutagen.ast`](../../.spec/specs/ast.spec.md).

  The lift is deliberately narrow: only helpers used by 2+ donor modules
  move here. Caller-specific helpers (`compute_end_position/1`,
  `walk_bare/N`, `node_line_range/1`, etc.) stay in their donor modules
  because only one caller uses them and they bake in caller-specific
  policy (e.g. ambient-position threading for the enumerator).

  Every function in this module is **pure**: takes AST, returns AST or
  a tagged result. No process state, no I/O, no side effects. That keeps
  the module trivially testable and lets callers compose freely.

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

  Walks `ast` with `Macro.prewalk/3`; returns the first match in
  depth-first source order.
  """
  @spec find_module_body(ast, String.t()) :: {:ok, ast} | :not_found
  def find_module_body(ast, target_mod_str) when is_binary(target_mod_str) do
    {_ast, acc} =
      Macro.prewalk(ast, :not_found, fn
        {:defmodule, _meta, [alias_ast, [do: body]]} = node, :not_found ->
          case alias_to_module(alias_ast) do
            nil ->
              {node, :not_found}

            mod_atom ->
              if module_string_matches?(mod_atom, target_mod_str) do
                {node, {:ok, body}}
              else
                {node, :not_found}
              end
          end

        node, acc ->
          {node, acc}
      end)

    acc
  end

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
