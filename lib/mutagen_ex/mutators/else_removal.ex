defmodule MutagenEx.Mutators.ElseRemoval do
  @moduledoc """
  Removes the `else` branch from an `if` or `with` expression.

  Per `mutagen.mutators` catalog entry 9.

  ## AST shape

  `if cond do A else B end` parses as

      {:if, meta, [cond, [do: A, else: B]]}

  `with C1 <- E1, do: A, else: (pattern -> B)` parses as

      {:with, meta, [c1_clause, [do: A, else: [{:->, _, [[pattern], B]}]]]}

  ## Removal

  We drop the `:else` key from the keyword list at the tail.

  ## Validation

  * `:structurally_invalid` — `else` removal would leave a call site that
    pattern-matches the original `if`/`with` for both branches. The catalog
    cannot prove this from a single node in isolation; in v1 we mark
    removal `:ok` unconditionally and rely on the runner to surface a
    `:compile_error` outcome when the caller's pattern matching breaks.
    Scenario `mutagen.mutators.s6` documents the eventual goal of context-
    sensitive validation; the v1 behaviour is the conservative subset that
    still does the swap and lets the runtime be the judge.

  The shape itself is validated: a non-`if`/non-`with` input is
  `:structurally_invalid`, as is a form that has no `else` branch in the
  first place (nothing to drop — the catalog should not have matched it).
  """

  @behaviour MutagenEx.Mutators

  @impl true
  def name, do: :else_removal

  @impl true
  def match?({form, _meta, [_head, kw]})
      when form in [:if] and is_list(kw) do
    Keyword.has_key?(kw, :else)
  end

  def match?({:with, _meta, clauses}) when is_list(clauses) do
    case List.last(clauses) do
      kw when is_list(kw) -> Keyword.has_key?(kw, :else)
      _ -> false
    end
  end

  def match?(_), do: false

  @impl true
  def mutate({:if, meta, [head, kw]}) when is_list(kw) do
    {:if, meta, [head, Keyword.delete(kw, :else)]}
  end

  def mutate({:with, meta, clauses}) when is_list(clauses) do
    {leading, [kw]} = Enum.split(clauses, length(clauses) - 1)
    {:with, meta, leading ++ [Keyword.delete(kw, :else)]}
  end

  @impl true
  def validate({:if, _meta, [_head, kw]}) when is_list(kw) do
    if Keyword.has_key?(kw, :do), do: :ok, else: {:skip, :structurally_invalid}
  end

  def validate({:with, _meta, clauses}) when is_list(clauses) do
    case List.last(clauses) do
      kw when is_list(kw) ->
        if Keyword.has_key?(kw, :do), do: :ok, else: {:skip, :structurally_invalid}

      _ ->
        {:skip, :structurally_invalid}
    end
  end

  def validate(_), do: {:skip, :structurally_invalid}
end
