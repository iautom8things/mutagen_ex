defmodule MutagenEx.Mutators.Dispatch do
  @moduledoc """
  Static, order-preserving head-atom dispatch table for the mutator catalog.

  Implements `mutagen.decision.static_mutator_dispatch`: the
  `MutagenEx.MutationEnumerator` consults `mutators_for_node/1` BEFORE
  calling `match?/1` on each catalog entry. The table maps an AST node's
  head atom to the (small) sub-sequence of mutators that could possibly
  match a node with that head; mutators that match shapes which are NOT
  3-tuples (bare literals, `{:ok, _}` / `{:error, _}` 2-tuples) live in a
  separate `@any_mutators` list and are always considered.

  ## Why this exists (and why it is a static table, not a behaviour callback)

  The enumerator's `try_mutators/6` used to run every mutator's `match?/1`
  against every AST node — `O(nodes × catalog_size)`. For files with even
  modest size this means asking ten mutators "do you match this `:+` node?"
  when only one possibly could. The dispatch table makes it
  `O(nodes × applicable_mutators)`.

  The scope auditor for `mutagen-wrd.25` flagged the alternative design —
  an `@optional_callback head_atoms/0` on the `MutagenEx.Mutators`
  behaviour — as bloat:

    * The mutator catalog is closed (`mutagen.mutators.r7`). No external
      mutator authors. The list of head atoms is small and trivially
      captured in one place.
    * An optional callback opens a drift surface: a future mutator could
      forget to declare its head atoms, dispatch would silently fall back
      to `:any` for it, and the optimisation would be defeated without
      anyone noticing.

  See `.spec/decisions/static_mutator_dispatch.md` for the full rationale.

  ## Determinism contract

  `mutators_for_node/1` returns a **sub-sequence** of
  `MutagenEx.Mutators.all/0`. The relative order of any two mutators in
  the result is identical to their relative order in `Mutators.all/0`.
  This is the property that preserves byte-identity of the JSON output
  across runs (`mutagen.mutation_enumeration.r1` and the technical
  red-team determinism finding called out in the decision file).

  Concretely: `Dispatch` builds the result by filtering
  `Mutators.all/0` — it never re-orders. The equivalence test
  (`test/mutagen_ex/head_atom_dispatch_test.exs`) locks both the
  correctness property (same mutators get tried per node) AND the
  order-preserving property (the filtered sub-sequence equals the
  result of the legacy "iterate `Mutators.all/0`" path applied to the
  same node).
  """

  alias MutagenEx.Mutators

  # Per-head-atom mutator list. The atoms here are the FIRST element of a
  # `{form, meta, args}` 3-tuple AST node — i.e. the syntactic head of an
  # expression as Elixir's parser produces it.
  #
  # Mutators that match shapes which are NOT 3-tuples (bare literals or
  # 2-tuples) live in `@any_mutators` instead and are tried for every
  # node regardless of head.
  #
  # The values in this table do not need to be in `Mutators.all/0` order;
  # ordering is enforced post-filter by `mutators_for_node/1` which
  # intersects against `Mutators.all/0`. Listing each mutator's heads
  # alongside its module keeps the table readable as a single map.
  @table %{
    # Arith: numeric binary ops.
    :+ => [Mutators.Arith],
    :- => [Mutators.Arith],
    :* => [Mutators.Arith],
    :/ => [Mutators.Arith],

    # Compare: comparison binary ops.
    :== => [Mutators.Compare],
    :!= => [Mutators.Compare],
    :< => [Mutators.Compare],
    :>= => [Mutators.Compare],
    :> => [Mutators.Compare],
    :<= => [Mutators.Compare],

    # Boolean: boolean binary ops + unary negation drops.
    :and => [Mutators.Boolean],
    :or => [Mutators.Boolean],
    :&& => [Mutators.Boolean],
    :|| => [Mutators.Boolean],
    :not => [Mutators.Boolean],
    :! => [Mutators.Boolean],

    # WithSwap and ElseRemoval both watch `:with` 3-tuples; ElseRemoval
    # also watches `:if`.
    :with => [Mutators.WithSwap, Mutators.ElseRemoval],
    :if => [Mutators.ElseRemoval],

    # CaseDrop: `case`/`cond` 3-tuples.
    :case => [Mutators.CaseDrop],
    :cond => [Mutators.CaseDrop],

    # Pipeline: `|>` 3-tuples (matches outer-of-two-stage form).
    :|> => [Mutators.Pipeline],

    # GuardDrop: `:when` 3-tuples (function-clause guards and
    # case/anonymous-function-clause guards alike).
    :when => [Mutators.GuardDrop]
  }

  # `:any` mutators run for every node regardless of head. These are the
  # mutators whose `match?/1` accepts shapes that are NOT
  # `{form, meta, args}` 3-tuples, OR whose match shapes do not have a
  # stable head atom we can key on.
  #
  #   * `Literal` matches bare scalar literals (`true`, `false`, `0`,
  #     `1`, `-1`) which carry no head atom of their own, AND the
  #     `{:__block__, meta, [scalar]}` wrapper that the parser emits
  #     around metadata-bearing literals. Keeping Literal in `:any` is
  #     simpler than splitting its match clauses across head-atom and
  #     `:any` buckets, and the cost is one extra `match?/1` call per
  #     node — cheap, given `Literal.match?/1` is a series of head-only
  #     function-clause matches.
  #   * `ResultTuple` matches plain 2-tuples `{:ok, x}` and
  #     `{:error, x}`. Those are tuple LITERALS in the AST, not
  #     3-tuple expression nodes — there is no head atom to key on.
  @any_mutators [
    Mutators.Literal,
    Mutators.ResultTuple
  ]

  @doc """
  Returns the sub-sequence of `MutagenEx.Mutators.all/0` whose `match?/1`
  could possibly match `node`, preserving `Mutators.all/0` order.

  The contract is:

    * Result is a list of mutator modules.
    * Result is a subset of `Mutators.all/0`.
    * The relative order of any two mutators in the result matches their
      relative order in `Mutators.all/0` (the order-preserving / byte-
      identity property required by
      `mutagen.mutation_enumeration.r1`).
    * Every mutator that would `match?(node)` is included in the
      result. (The converse is allowed: the result MAY include a mutator
      whose `match?/1` then returns `false` — `mutators_for_node/1` is a
      cheap **pre-filter**, not a full classifier. The enumerator still
      calls `match?/1` on each candidate.)

  The equivalence test in
  `test/mutagen_ex/head_atom_dispatch_test.exs` locks both properties
  against the legacy "iterate `Mutators.all/0`" path for a corpus of
  representative AST nodes.
  """
  @spec mutators_for_node(Macro.t()) :: [module()]
  def mutators_for_node(node) do
    candidates = candidates_set(node)
    Enum.filter(Mutators.all(), &MapSet.member?(candidates, &1))
  end

  # Build the set of mutator modules potentially relevant for `node`:
  # always include `@any_mutators`, and for 3-tuple nodes also include
  # the head-keyed entries (if any).
  defp candidates_set({head, _meta, _args}) when is_atom(head) do
    head_specific = Map.get(@table, head, [])
    MapSet.new(@any_mutators ++ head_specific)
  end

  defp candidates_set(_other) do
    # Not a 3-tuple — bare scalar literals, 2-tuples, lists, atoms, etc.
    # No head atom to key on; only the `:any` mutators are candidates.
    MapSet.new(@any_mutators)
  end
end
