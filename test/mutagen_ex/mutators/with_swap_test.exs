defmodule MutagenEx.Mutators.WithSwapTest do
  use ExUnit.Case, async: true

  alias MutagenEx.Mutators.WithSwap

  test "name is :with_swap" do
    assert WithSwap.name() == :with_swap
  end

  describe "match?/1" do
    test "matches `with` with at least two <- clauses" do
      ast = Code.string_to_quoted!("with {:ok, a} <- f(), {:ok, b} <- g(), do: a + b")
      assert WithSwap.match?(ast)
    end

    test "does not match `with` with only one <- clause" do
      ast = Code.string_to_quoted!("with {:ok, a} <- f(), do: a")
      refute WithSwap.match?(ast)
    end

    test "does not match other forms" do
      refute WithSwap.match?(Code.string_to_quoted!("a + b"))
    end
  end

  describe "mutate/1" do
    test "swaps the first two <- clauses, preserving the do block" do
      ast = Code.string_to_quoted!("with {:ok, a} <- f(), {:ok, b} <- g(), do: a + b")
      mutated = WithSwap.mutate(ast)

      assert {:with, _, [{:<-, _, [first_pat, first_expr]}, {:<-, _, _} | rest]} = mutated

      assert match?({:ok, {:b, _, _}}, first_pat)
      assert match?({:g, _, _}, first_expr)
      # do-block is preserved
      assert [[do: _]] = rest
    end
  end

  describe "validate/1" do
    @tag :validate
    test "{:skip, :bound_var_used_before_binding} when swapped expr references newly-second-bound var (scenario s2)" do
      ast = Code.string_to_quoted!("with {:ok, a} <- f(), {:ok, b} <- g(a), do: a + b")
      swapped = WithSwap.mutate(ast)
      assert WithSwap.validate(swapped) == {:skip, :bound_var_used_before_binding}
    end

    @tag :validate
    test ":ok when the two clauses are independent" do
      ast = Code.string_to_quoted!("with {:ok, a} <- f(), {:ok, b} <- g(), do: a + b")
      swapped = WithSwap.mutate(ast)
      assert WithSwap.validate(swapped) == :ok
    end

    @tag :validate
    test "{:skip, :structurally_invalid} on non-with input" do
      assert WithSwap.validate(42) == {:skip, :structurally_invalid}
    end
  end
end
