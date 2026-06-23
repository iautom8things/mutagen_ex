defmodule MutagenEx.Mutators.CaseDropTest do
  use ExUnit.Case, async: true

  alias MutagenEx.Mutators.CaseDrop

  describe "name/0" do
    test "name is :case_drop" do
      assert CaseDrop.name() == :case_drop
    end
  end

  describe "match?/1" do
    test "matches `case` with ≥2 clauses" do
      ast = Code.string_to_quoted!("case x do 1 -> :a; 2 -> :b end")
      assert CaseDrop.match?(ast)
    end

    test "matches `cond` with ≥2 clauses" do
      ast = Code.string_to_quoted!("cond do a -> :a; b -> :b end")
      assert CaseDrop.match?(ast)
    end

    test "does not match `case` with one clause" do
      ast = Code.string_to_quoted!("case x do 1 -> :a end")
      refute CaseDrop.match?(ast)
    end

    test "does not match other forms" do
      refute CaseDrop.match?(Code.string_to_quoted!("a + b"))
    end
  end

  describe "mutate/1" do
    test "drops the last clause of a `case`" do
      ast = Code.string_to_quoted!("case x do 1 -> :a; 2 -> :b end")
      mutated = CaseDrop.mutate(ast)
      assert {:case, _, [_subject, [do: clauses]]} = mutated
      assert length(clauses) == 1
      assert match?([{:->, _, [[1], :a]}], clauses)
    end

    test "drops the last clause of a `cond`" do
      ast = Code.string_to_quoted!("cond do a -> :a; b -> :b end")
      mutated = CaseDrop.mutate(ast)
      assert {:cond, _, [[do: clauses]]} = mutated
      assert length(clauses) == 1
    end
  end

  describe "validate/1" do
    @tag :validate
    test ":ok when remaining clauses still form a valid case body" do
      ast = Code.string_to_quoted!("case x do 1 -> :a; 2 -> :b end")
      assert CaseDrop.validate(CaseDrop.mutate(ast)) == :ok
    end

    @tag :validate
    test ":skip on non-case/non-cond input" do
      assert CaseDrop.validate(42) == {:skip, :structurally_invalid}
    end
  end
end
