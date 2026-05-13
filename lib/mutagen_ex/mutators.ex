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

  `site_id/3` produces the content-addressed mutation ID per
  `mutagen.mutators.r3` and `mutagen.decision.content_addressed_ids`:

      "#{relative_file}:#{:erlang.phash2(normalized_ast)}:#{mutator_name}"

  Normalization strips `:line`, `:column`, `:end_line`, and `:end_column` from
  every metadata keyword in the AST before hashing. This is what makes IDs
  stable across `mix format` (`mutagen.mutators.r4`).

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

  @doc ~S"""
  Computes the content-addressed site ID for a mutation site.

  Format: `"#{relative_file}:#{ast_hash}:#{mutator_name}"`, where `ast_hash`
  is `:erlang.phash2/2` of `node` after stripping positional metadata
  (`:line`, `:column`, `:end_line`, `:end_column`).

  Per `mutagen.mutators.r3` the file path is relative to the project root;
  callers are responsible for passing a relative path (this function does no
  path normalisation of its own). Per `mutagen.mutators.r4` the hash is
  invariant under `mix format` because positional metadata is stripped before
  hashing.
  """
  @spec site_id(String.t(), ast_node, mutator_name()) :: String.t()
  def site_id(relative_file, node, mutator_name)
      when is_binary(relative_file) and is_atom(mutator_name) do
    "#{relative_file}:#{ast_hash(node)}:#{mutator_name}"
  end

  @doc """
  Returns `:erlang.phash2/2` of `node` after positional metadata is stripped.

  Exposed as a public helper so the enumerator and tests can compute the
  hash directly without rebuilding a site ID.
  """
  @spec ast_hash(ast_node) :: non_neg_integer()
  def ast_hash(node) do
    :erlang.phash2(normalize(node))
  end

  @doc """
  Strips `:line`, `:column`, `:end_line`, and `:end_column` from every
  metadata keyword in an AST. Other metadata (e.g. `:context`) is preserved
  per `mutagen.decision.content_addressed_ids`.

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
