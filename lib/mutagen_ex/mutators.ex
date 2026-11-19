defmodule MutagenEx.Mutators do
  @moduledoc ~S"""
  Registry and behaviour for the ten v1 mutators.

  Each mutator is a module implementing `MutagenEx.Mutators` callbacks:

    * `name/0` — the snake_case atom name (e.g. `:arith`) used in site IDs.
    * `match?/1` — predicate over an AST node deciding whether the node is a
      candidate for this mutator.
    * `mutate/1` — produces the swapped AST node. Pure; performs no I/O.
    * `validate/1` — runs after `mutate/1` and before any compile to decide
      whether the swap is sensible. Returns `:ok` or `{:skip, reason}` where
      `reason` is one of `:structurally_invalid`, `:no_op_shadowed`, or
      `:bound_var_used_before_binding` per
      `mutagen.decision.validate_predicates`.

  ## Catalog

  The catalog is closed in v1 (`mutagen.mutators.r7`): ten mutators, no
  plugin interface, no user-supplied addition. Adding a new mutator requires
  a code change here AND a corresponding `mutagen.mutators` spec revision.

  ## Site IDs

  `site_id/3` hashes the enclosing definition, normalized node, and
  occurrence ordinal. The enumerator supplies that identity in file walk
  order. See `mutagen.decision.mutation_id_scheme_2`.

  ## Out of scope here

  This module enumerates the catalog and computes IDs. It does **not** walk
  a source file looking for sites (that is the enumerator's job in S4b)
  and it does **not** compile or run mutated code (that is the runner's
  job in S5). Per the ticket's Out of Scope (intent): "Do not run any
  mutated code. The catalog is pure AST manipulation."
  """

  @typedoc "AST node as returned by `Code.string_to_quoted/2`."
  @type ast_node :: Macro.t()

  @typedoc "Snake_case atom name of a mutator (`:arith`, `:case_drop`, …)."
  @type mutator_name :: atom()

  @typedoc "Outcome of `validate/1`. `:ok` keeps the site; `{:skip, reason}` drops it."
  @type validation_result :: :ok | {:skip, atom()}

  @callback name() :: mutator_name()
  @callback match?(ast_node) :: boolean()
  @callback mutate(ast_node) :: ast_node
  @callback validate(ast_node) :: validation_result

  @mutators [
    MutagenEx.Mutators.Arith,
    MutagenEx.Mutators.Compare,
    MutagenEx.Mutators.Boolean,
    MutagenEx.Mutators.Literal,
    MutagenEx.Mutators.WithSwap,
    MutagenEx.Mutators.CaseDrop,
    MutagenEx.Mutators.Pipeline,
    MutagenEx.Mutators.ResultTuple,
    MutagenEx.Mutators.ElseRemoval,
    MutagenEx.Mutators.GuardDrop
  ]

  @doc """
  Returns the closed list of v1 mutator modules in their canonical order.

  The order is significant: site enumeration walks mutators in this order so
  IDs are deterministic when two mutators happen to match the same node.
  """
  @spec all() :: [module()]
  def all, do: @mutators

  @doc """
  Returns the snake_case atom name of every catalog entry, in `all/0` order.
  """
  @spec names() :: [mutator_name()]
  def names, do: Enum.map(@mutators, & &1.name())

  @doc """
  Looks up a mutator module by its `name/0` value. Returns `nil` if the name
  is not in the v1 catalog.
  """
  @spec fetch(mutator_name()) :: module() | nil
  def fetch(name) when is_atom(name) do
    Enum.find(@mutators, &(&1.name() == name))
  end

  @doc "Builds a scheme 2 ID from a project-relative path and a normalized identity."
  @spec site_id(String.t(), {tuple() | nil, ast_node(), non_neg_integer()}, mutator_name()) ::
          String.t()
  def site_id(relative_file, {enclosing, node, ordinal}, mutator_name) do
    hash =
      {enclosing, node, ordinal}
      |> :erlang.term_to_binary([:deterministic])
      |> :erlang.md5()
      |> Base.encode16(case: :lower)

    "#{relative_file}:#{hash}:#{mutator_name}"
  end

  # Compiler resolution metadata is significant even when the AST shape agrees.
  @identity_metadata [:alias, :context, :counter, :if_undefined, :imports, :no_parens]

  @doc false
  @spec identity_node(ast_node()) :: ast_node()
  def identity_node(ast) do
    Macro.prewalk(ast, fn
      {form, meta, args} when is_list(meta) ->
        {form, identity_metadata(form, meta), args}

      other ->
        other
    end)
  end

  defp identity_metadata({:., _, [receiver, _name]}, meta) do
    meta = if module_receiver?(receiver), do: Keyword.delete(meta, :no_parens), else: meta
    keep_identity_metadata(meta)
  end

  defp identity_metadata(_form, meta), do: keep_identity_metadata(meta)

  defp keep_identity_metadata(meta) do
    meta |> Keyword.take(@identity_metadata) |> Enum.sort_by(&elem(&1, 0))
  end

  defp module_receiver?({:__aliases__, _, _}), do: true
  defp module_receiver?({:__MODULE__, _, context}) when is_atom(context), do: true

  defp module_receiver?(receiver),
    do: is_atom(receiver) and not is_nil(receiver) and not is_boolean(receiver)

  @doc """
  Strips `:line`, `:column`, `:end_line`, and `:end_column` from every
  metadata keyword in an AST. This comparison helper preserves all other
  metadata for mutator validation.

  Walks the entire tree, including children inside metadata-bearing tuples
  and inside lists/tuples of further AST nodes.
  """
  @spec normalize(ast_node) :: ast_node
  def normalize(ast) do
    Macro.prewalk(ast, fn
      {form, meta, args} when is_list(meta) ->
        {form, strip_positional(meta), args}

      other ->
        other
    end)
  end

  @positional_keys [:line, :column, :end_line, :end_column]

  defp strip_positional(meta) do
    Enum.reject(meta, fn
      {key, _value} -> key in @positional_keys
      _ -> false
    end)
  end
end
