defmodule MutagenEx.Mutators.ArithTest do
  use ExUnit.Case, async: true

  alias MutagenEx.Mutators.Arith

  test "name is :arith" do
    assert Arith.name() == :arith
  end

  describe "match?/1" do
    test "matches numeric +, -, *, /" do
      for src <- ["a + 1", "a - 1", "a * 2", "a / 2"] do
        assert Arith.match?(Code.string_to_quoted!(src)), "expected match on #{src}"
      end
    end

    test "does not match other operators" do
      for src <- ["a == 1", "a && b", "a |> f()", "[1, 2, 3]", "a"] do
        refute Arith.match?(Code.string_to_quoted!(src)), "unexpected match on #{src}"
      end
    end
  end

  describe "mutate/1" do
    @tag :validate
    test "swaps + and -" do
      {:ok, plus} = Code.string_to_quoted("a + 1")
      assert {:-, _, [{:a, _, _}, 1]} = Arith.mutate(plus)

      {:ok, minus} = Code.string_to_quoted("a - 1")
      assert {:+, _, [{:a, _, _}, 1]} = Arith.mutate(minus)
    end

    test "swaps * and /" do
      {:ok, mul} = Code.string_to_quoted("a * 2")
      assert {:/, _, [{:a, _, _}, 2]} = Arith.mutate(mul)

      {:ok, div} = Code.string_to_quoted("a / 2")
      assert {:*, _, [{:a, _, _}, 2]} = Arith.mutate(div)
    end

    test "mutate is involutive (mutate(mutate(node)) == node)" do
      for src <- ["a + 1", "a - 1", "a * 2", "a / 2"] do
        ast = Code.string_to_quoted!(src)
        assert Arith.mutate(Arith.mutate(ast)) == ast
      end
    end
  end

  describe "validate/1" do
    @tag :validate
    test "returns :ok for well-shaped binary arith" do
      for src <- ["a + 1", "a - 1", "a * 2", "a / 2"] do
        ast = Code.string_to_quoted!(src)
        assert Arith.validate(Arith.mutate(ast)) == :ok
      end
    end

    @tag :validate
    test "returns {:skip, :structurally_invalid} on non-arith input" do
      assert Arith.validate(:not_an_ast) == {:skip, :structurally_invalid}
    end
  end
end
