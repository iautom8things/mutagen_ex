defmodule MutagenEx.Mutators.CaseDropClassificationTest do
  @moduledoc """
  Pins the documented runtime classification of `:case_drop` against a
  guarded-recursive-base-case pattern (mutagen.mutators.r8 /
  mutagen.mutation_pipeline.r5).

  The spec promises:

  - `validate/1` returns `:ok` even when the surviving clauses do not
    cover every runtime-reachable value (the catalog does not prove
    coverage).
  - At runtime, the mutated module raises `CaseClauseError` once the
    recursion reaches the value that the dropped clause matched.
  - Therefore `:case_drop` is NOT a reliable trigger for `:timeout`;
    the pipeline classifies the site `:killed` (the cited test fails
    on `CaseClauseError`).

  This test demonstrates the AST + runtime behaviour directly so future
  reorganization cannot silently regress the contract.
  """

  use ExUnit.Case, async: true

  alias MutagenEx.Mutators.CaseDrop

  @guarded_recursive_base_case """
  case n do
    n when n > 0 -> n - 1
    0 -> :done
  end
  """

  describe "guarded-recursive-base-case pattern (mutagen.mutators.r8)" do
    test "case_drop's validate/1 returns :ok — the catalog does not prove coverage" do
      ast = Code.string_to_quoted!(@guarded_recursive_base_case)
      mutated = CaseDrop.mutate(ast)

      # The catalog refuses to skip this site even though the surviving
      # clause (`n when n > 0 -> ...`) does not match `n == 0`. This is
      # the conservative v1 behaviour documented in
      # mutagen.mutators.r2 / mutagen.decision.validate_predicates.
      assert CaseDrop.validate(mutated) == :ok
    end

    test "mutated source raises CaseClauseError on the dropped value (not :timeout)" do
      ast = Code.string_to_quoted!(@guarded_recursive_base_case)
      mutated = CaseDrop.mutate(ast)

      # The surviving clause has the n > 0 guard. Binding n = 0 falls
      # through every remaining clause and Elixir raises CaseClauseError.
      assert_raise CaseClauseError, ~r/no case clause matching/, fn ->
        Code.eval_quoted(mutated, n: 0)
      end
    end

    test "mutated source evaluates normally when guard matches" do
      # Sanity check the other side of the contract: when the recursion
      # has not yet reached the dropped value, the case still evaluates.
      ast = Code.string_to_quoted!(@guarded_recursive_base_case)
      mutated = CaseDrop.mutate(ast)

      assert {2, _} = Code.eval_quoted(mutated, n: 3)
    end
  end

  describe "deterministic-timeout trigger note (mutagen.mutators.r8 corollary)" do
    test ":arith on the recursive descent is the documented :timeout trigger" do
      # The spec note for r8 directs fixture authors away from :case_drop
      # for deterministic :timeout and toward :arith against the recursive
      # descent. This test pins the AST-level swap so the documented
      # corollary stays falsifiable: flipping `n - 1` to `n + 1` keeps
      # the case head guard (n > 0) true on every iteration, so the
      # recursion diverges without encountering a clause-miss.
      descent_ast = Code.string_to_quoted!("n - 1")
      assert MutagenEx.Mutators.Arith.match?(descent_ast)

      mutated = MutagenEx.Mutators.Arith.mutate(descent_ast)

      assert {:+, _, [{:n, _, _}, 1]} = mutated
    end
  end
end
