defmodule MutagenEx.Mutators.ElseRemovalTest do
  use ExUnit.Case, async: true

  alias MutagenEx.Mutators.ElseRemoval

  test "name is :else_removal" do
    assert ElseRemoval.name() == :else_removal
  end

  describe "match?/1" do
    test "matches `if ... else ...`" do
      assert ElseRemoval.match?(Code.string_to_quoted!("if x do :a else :b end"))
    end

    test "does not match `if` without else" do
      refute ElseRemoval.match?(Code.string_to_quoted!("if x do :a end"))
    end

    test "matches `with ... else ...`" do
      src = "with {:ok, a} <- f(), do: a, else: (_ -> :err)"
      assert ElseRemoval.match?(Code.string_to_quoted!(src))
    end

    test "does not match `with` without else" do
      src = "with {:ok, a} <- f(), do: a"
      refute ElseRemoval.match?(Code.string_to_quoted!(src))
    end
  end

  describe "mutate/1" do
    test "removes :else from `if` keyword list" do
      ast = Code.string_to_quoted!("if x do :a else :b end")
      mutated = ElseRemoval.mutate(ast)
      assert {:if, _, [_cond, kw]} = mutated
      assert Keyword.fetch!(kw, :do) == :a
      refute Keyword.has_key?(kw, :else)
    end

    test "removes :else from `with`'s trailing keyword list" do
      src = "with {:ok, a} <- f(), do: a, else: (_ -> :err)"
      ast = Code.string_to_quoted!(src)
      mutated = ElseRemoval.mutate(ast)
      assert {:with, _, clauses} = mutated
      kw = List.last(clauses)
      assert Keyword.has_key?(kw, :do)
      refute Keyword.has_key?(kw, :else)
    end
  end

  describe "validate/1" do
    @tag :validate
    test ":ok for `if` once else is removed (do remains)" do
      ast = Code.string_to_quoted!("if x do :a else :b end")
      assert ElseRemoval.validate(ElseRemoval.mutate(ast)) == :ok
    end

    @tag :validate
    test ":ok for `with` once else is removed" do
      src = "with {:ok, a} <- f(), do: a, else: (_ -> :err)"
      ast = Code.string_to_quoted!(src)
      assert ElseRemoval.validate(ElseRemoval.mutate(ast)) == :ok
    end

    @tag :validate
    test ":skip on non-conditional input" do
      assert ElseRemoval.validate(42) == {:skip, :structurally_invalid}
    end
  end
end
