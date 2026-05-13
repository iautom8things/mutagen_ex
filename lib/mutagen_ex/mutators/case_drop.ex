defmodule MutagenEx.Mutators.CaseDrop do
  @moduledoc """
  Drops the last clause of a `case` or `cond` expression.

  Per `mutagen.mutators` catalog entry 6.

  ## AST shape

  `case subject do C1 -> R1; C2 -> R2 end` parses as

      {:case, meta, [subject, [do: [
        {:->, meta, [[pattern1], result1]},
        {:->, meta, [[pattern2], result2]}
      ]]]}

  `cond do C1 -> R1; C2 -> R2 end` parses similarly with `:cond` and a single
  expression in each clause's pattern list.

  ## Drop

  We drop the **last** clause. Dropping the catch-all or wildcard is what
  changes observable behaviour for the most realistic call sites. Dropping
  the only clause would yield invalid AST so we skip those.

  ## Validation

  * `:structurally_invalid` — `case`/`cond` with only one clause (dropping it
    leaves an empty `do` block, which does not compile).
  * `:no_op_shadowed` — `case`/`cond` whose remaining clauses still cover
    every value that reaches the expression. The catalog cannot prove
    coverage in general; in v1 we conservatively skip nothing here so the
    runner's `:survived` count remains an honest upper bound. Users should
    interpret a surviving `case_drop` mutation as "test suite did not
    distinguish the dropped branch from the remaining branches".
  """

  @behaviour MutagenEx.Mutators

  @impl true
  def name, do: :case_drop

  @impl true
  def match?({form, _meta, [_subject, [do: clauses]]})
      when form in [:case] and is_list(clauses) and length(clauses) >= 2 do
    true
  end

  def match?({:cond, _meta, [[do: clauses]]})
      when is_list(clauses) and length(clauses) >= 2 do
    true
  end

  def match?(_), do: false

  @impl true
  def mutate({:case, meta, [subject, [do: clauses]]}) do
    {:case, meta, [subject, [do: drop_last(clauses)]]}
  end

  def mutate({:cond, meta, [[do: clauses]]}) do
    {:cond, meta, [[do: drop_last(clauses)]]}
  end

  @impl true
  def validate({:case, _meta, [_subject, [do: clauses]]}) when is_list(clauses) do
    validate_clauses(clauses)
  end

  def validate({:cond, _meta, [[do: clauses]]}) when is_list(clauses) do
    validate_clauses(clauses)
  end

  def validate(_), do: {:skip, :structurally_invalid}

  defp validate_clauses([]), do: {:skip, :structurally_invalid}
  defp validate_clauses(clauses) when is_list(clauses), do: :ok

  defp drop_last(list), do: Enum.take(list, length(list) - 1)
end
