defmodule MutagenEx.Mutators.WithSwapTest do
  use ExUnit.Case, async: true

  alias MutagenEx.Mutators.WithSwap

  describe "name/0" do
    test "name is :with_swap" do
      assert WithSwap.name() == :with_swap
    end
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
    test "skips two unconditional bindings even with else" do
      assert validate_swap("with a <- f(), _ <- g(), do: a, else: (_ -> :error)") ==
               {:skip, :insufficient_refutable_patterns}
    end

    @tag :validate
    test "skips when only one of the two swapped matches can fail" do
      for source <- [
            "with a <- f(), :ok <- g(), do: a",
            "with :ok <- f(), a <- g(), do: a",
            "with :ok <- :ok, :ok <- g(), do: :done",
            "with a <- f(), b <- g(), :ok <- h(), do: {a, b}"
          ] do
        assert validate_swap(source) == {:skip, :insufficient_refutable_patterns}, source
      end
    end

    @tag :validate
    test "skips identical failure values even with different patterns or an else that returns its input" do
      for source <- [
            "with :left <- input, :right <- input, do: :done, else: (error -> error)",
            "with :left <- {:error, :bad}, :right <- {:error, :bad}, do: :done"
          ] do
        assert validate_swap(source) == {:skip, :indistinguishable_failures}, source
      end
    end

    @tag :validate
    test "keeps distinct literal failures and treats even repeated calls as opaque" do
      for source <- [
            "with :ok <- {:error, :left}, :ok <- {:error, :right}, do: :done",
            "with :ok <- f(), :ok <- f(), do: :done"
          ] do
        assert validate_swap(source) == :ok, source
      end
    end

    @tag :validate
    test "skips a single wildcard else but keeps an else that uses the failure value" do
      assert validate_swap("with :ok <- f(), :ok <- g(), do: :done, else: (_ -> :error)") ==
               {:skip, :else_ignores_failure}

      assert validate_swap("with :ok <- f(), :ok <- g(), do: :done, else: (error -> error)") ==
               :ok
    end

    @tag :validate
    test "keeps a failure-sensitive else and leaves the third clause in place" do
      {:with, _, [first, second, third, blocks]} =
        ast =
        Code.string_to_quoted!("""
        with {:ok, a} <- first(),
             {:ok, b} <- second(),
             {:ok, c} <- third(a, b) do
          c
        else
          {:error, reason} -> {:rejected, reason}
          _ -> :unknown
        end
        """)

      swapped = WithSwap.mutate(ast)
      assert {:with, _, [^second, ^first, ^third, ^blocks]} = swapped
      assert WithSwap.validate(swapped) == :ok
    end

    @tag :validate
    test "pins and guarded variables can fail and their outer references do not introduce bindings" do
      assert validate_swap("with ^expected <- f(), {:ok, value} <- g(expected), do: value") == :ok

      assert validate_swap(
               "with a when a > limit <- f(), b when is_integer(b) <- g(limit), do: {a, b}"
             ) == :ok
    end

    @tag :validate
    test "the moved clause cannot pin or guard against a binding that now comes later" do
      for source <- [
            "with {:ok, a} <- f(), ^a <- g(), do: a",
            "with {:ok, a} <- f(), b when b > a <- g(), do: b",
            "with _a <- f(), :ok <- g(_a), do: :done"
          ] do
        assert validate_swap(source) == {:skip, :bound_var_used_before_binding}, source
      end
    end

    @tag :validate
    test "{:skip, :structurally_invalid} on non-with input" do
      assert WithSwap.validate(42) == {:skip, :structurally_invalid}
    end
  end

  defp validate_swap(source) do
    source
    |> Code.string_to_quoted!(columns: true, token_metadata: true)
    |> WithSwap.mutate()
    |> WithSwap.validate()
  end
end
