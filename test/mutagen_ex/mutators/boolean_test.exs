defmodule MutagenEx.Mutators.BooleanTest do
  use ExUnit.Case, async: true

  alias MutagenEx.Mutators.Boolean

  test "name is :boolean" do
    assert Boolean.name() == :boolean
  end

  describe "match?/1" do
    test "matches and/or and &&/||" do
      for src <- ["a and b", "a or b", "a && b", "a || b"] do
        assert Boolean.match?(Code.string_to_quoted!(src)), src
      end
    end

    test "matches not and !" do
      assert Boolean.match?(Code.string_to_quoted!("not x"))
      assert Boolean.match?(Code.string_to_quoted!("!x"))
    end

    test "does not match arithmetic or comparison" do
      for src <- ["a + b", "a == b"] do
        refute Boolean.match?(Code.string_to_quoted!(src))
      end
    end
  end

  describe "mutate/1" do
    test "and <-> or" do
      assert {:or, _, _} = Boolean.mutate(Code.string_to_quoted!("a and b"))
      assert {:and, _, _} = Boolean.mutate(Code.string_to_quoted!("a or b"))
    end

    test "&& <-> ||" do
      assert {:||, _, _} = Boolean.mutate(Code.string_to_quoted!("a && b"))
      assert {:&&, _, _} = Boolean.mutate(Code.string_to_quoted!("a || b"))
    end

    test "drops `not` and `!`" do
      assert Boolean.mutate(Code.string_to_quoted!("not x")) ==
               Code.string_to_quoted!("x")

      assert Boolean.mutate(Code.string_to_quoted!("!x")) ==
               Code.string_to_quoted!("x")
    end

    test "binary swaps are involutive" do
      for src <- ["a and b", "a or b", "a && b", "a || b"] do
        ast = Code.string_to_quoted!(src)
        assert Boolean.mutate(Boolean.mutate(ast)) == ast
      end
    end
  end

  describe "validate/1" do
    @tag :validate
    test ":ok on mutated binary forms" do
      for src <- ["a and b", "a || b"] do
        ast = Code.string_to_quoted!(src)
        assert Boolean.validate(Boolean.mutate(ast)) == :ok
      end
    end

    @tag :validate
    test ":ok after dropping `not`/`!` (operand was already valid)" do
      assert Boolean.validate(Boolean.mutate(Code.string_to_quoted!("not x"))) == :ok
      assert Boolean.validate(Boolean.mutate(Code.string_to_quoted!("!x"))) == :ok
    end
  end
end
