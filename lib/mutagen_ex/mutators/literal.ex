defmodule MutagenEx.Mutators.Literal do
  @moduledoc """
  Flips `true ↔ false` and swaps small integer literals: `0 ↔ 1`, `1 ↔ 0`,
  `-1 → 1`.

  Per `mutagen.mutators` catalog entry 4.

  The boolean flip is fully symmetric.

  The integer rewrite is restricted to the literals `0`, `1`, and `-1` so
  the swap stays within "small integer" territory and so reversibility is
  well-defined:

    * `0 → 1`
    * `1 → 0`
    * `-1 → 1`

  Wider integers are intentionally out of scope: the catalog is closed in
  v1 (`mutagen.mutators.r7`), and adding configurable integer pools would
  cross that line.

  ## AST shapes (bw mutagen-wrd.15)

  `mix mutagen` parses source with `Code.string_to_quoted(..., token_metadata:
  true, columns: true)` (see `lib/mutagen_ex/ast_cache.ex`). Atomic literals
  appear in the parsed AST in **two** shapes that the enumerator's
  `Macro.prewalk/3` traversal can visit:

    1. **Bare** — the literal stands alone as a child of an operator, case
       clause head, etc. (e.g., the `0` in `{:>, _, [n, 0]}` or the `1` in
       `{:->, _, [[1], :one]}`). The bare child carries no metadata of its
       own; it is matched here by the unwrapped clauses.
    2. **`__block__`-wrapped** — the parser wraps a literal in a metadata-
       carrying `{:__block__, meta, [value]}` 3-tuple when it needs to
       attach token / line / column info to the literal directly. The
       enumerator's `node_line/1` extracts the line from the wrapper's
       `meta`; an unwrapped match would lose that line and the enumerator
       would drop the site (`is_nil(line) -> acc` at
       `mutation_enumerator.ex:224`).

  Both shapes match; mutating a `__block__`-wrapped literal preserves the
  wrapper (and therefore the line/column metadata) so the rewritten AST is
  also a 3-tuple the enumerator can attribute to a source line.

  Hashing-stability invariant: `MutagenEx.Mutators.normalize/1` strips
  `:line`, `:column`, `:end_line`, `:end_column` from every metadata
  keyword before `:erlang.phash2`. The `__block__` wrapper around a
  literal therefore hashes to the same value across reformatting; the
  bare-value and wrapped-value shapes intentionally hash differently
  because they are distinct AST nodes per Elixir's own equality.
  """

  @behaviour MutagenEx.Mutators

  @impl true
  def name, do: :literal

  @impl true
  # Bare-value clauses.
  def match?(true), do: true
  def match?(false), do: true
  def match?(0), do: true
  def match?(1), do: true
  def match?(-1), do: true

  # `__block__`-wrapped clauses (bw mutagen-wrd.15).
  def match?({:__block__, meta, [true]}) when is_list(meta), do: true
  def match?({:__block__, meta, [false]}) when is_list(meta), do: true
  def match?({:__block__, meta, [0]}) when is_list(meta), do: true
  def match?({:__block__, meta, [1]}) when is_list(meta), do: true
  def match?({:__block__, meta, [-1]}) when is_list(meta), do: true

  def match?(_), do: false

  @impl true
  # Bare-value clauses.
  def mutate(true), do: false
  def mutate(false), do: true
  def mutate(0), do: 1
  def mutate(1), do: 0
  def mutate(-1), do: 1

  # `__block__`-wrapped clauses preserve the wrapper's positional metadata
  # (`:line`, `:column`) so the swapped node carries the same source
  # coordinates as the original (so the enumerator can attribute the swap
  # to the same source line) and so the AST remains in the same shape the
  # enumerator's surrounding traversal produced.
  #
  # The `:token` metadata key is stripped on swap: with `token_metadata:
  # true` the parser records the exact source token (e.g. `"true"`,
  # `"0"`) and `Macro.to_string/1` reproduces THAT token verbatim,
  # ignoring the wrapped value. Leaving `:token` in place would make
  # `Macro.to_string(mutate(node))` round-trip to the ORIGINAL value, not
  # the swapped one — breaking the AST-to-source bridge invariant
  # (`mutagen.mutators.r6`). Stripping `:token` lets `Macro.to_string/1`
  # render the swapped value as a fresh literal.
  def mutate({:__block__, meta, [true]}) when is_list(meta),
    do: {:__block__, strip_token(meta), [false]}

  def mutate({:__block__, meta, [false]}) when is_list(meta),
    do: {:__block__, strip_token(meta), [true]}

  def mutate({:__block__, meta, [0]}) when is_list(meta),
    do: {:__block__, strip_token(meta), [1]}

  def mutate({:__block__, meta, [1]}) when is_list(meta),
    do: {:__block__, strip_token(meta), [0]}

  def mutate({:__block__, meta, [-1]}) when is_list(meta),
    do: {:__block__, strip_token(meta), [1]}

  defp strip_token(meta), do: Keyword.delete(meta, :token)

  @impl true
  # Bare-value validate.
  def validate(value) when is_boolean(value), do: :ok
  def validate(value) when is_integer(value), do: :ok

  # `__block__`-wrapped validate: the swap produced a `{:__block__, _, [v]}`
  # whose inner value is a boolean or integer literal. Per
  # `mutagen.mutators.r6`, `Macro.to_string/1` of the wrapped form must
  # round-trip through `Code.string_to_quoted/2`; the wrapper is exactly
  # what the parser emits, so the round-trip is by-construction.
  def validate({:__block__, meta, [value]}) when is_list(meta) and is_boolean(value), do: :ok
  def validate({:__block__, meta, [value]}) when is_list(meta) and is_integer(value), do: :ok

  def validate(_), do: {:skip, :structurally_invalid}
end
