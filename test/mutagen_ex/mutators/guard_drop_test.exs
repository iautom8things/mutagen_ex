defmodule MutagenEx.Mutators.GuardDropTest do
  use ExUnit.Case, async: true

  alias MutagenEx.Mutators.GuardDrop

  test "name is :guard_drop" do
    assert GuardDrop.name() == :guard_drop
  end

  describe "match?/1" do
    test "matches a `:when` AST node (the guard wrapper)" do
      {:def, _, [head, _]} = Code.string_to_quoted!("def f(x) when x > 0, do: x")
      assert GuardDrop.match?(head)
    end

    test "matches multi-guard form" do
      {:def, _, [head, _]} =
        Code.string_to_quoted!("def f(x) when is_integer(x) when x > 0, do: x")

      assert GuardDrop.match?(head)
    end

    test "does not match a head without guard" do
      {:def, _, [head, _]} = Code.string_to_quoted!("def f(x), do: x")
      refute GuardDrop.match?(head)
    end
  end

  describe "mutate/1" do
    test "removes the guard, returning the pattern head" do
      {:def, _, [head, _]} = Code.string_to_quoted!("def f(x) when x > 0, do: x")
      mutated = GuardDrop.mutate(head)
      # Drops the {:when, _, [head, guard]} wrapper, returns the head.
      assert {:f, _, [{:x, _, _}]} = mutated
    end
  end

  describe "validate/1" do
    @tag :validate
    test ":ok when input was the expected wrapper" do
      {:def, _, [head, _]} = Code.string_to_quoted!("def f(x) when x > 0, do: x")
      assert GuardDrop.validate(head) == :ok
    end

    @tag :validate
    test ":skip on non-guard input" do
      assert GuardDrop.validate(42) == {:skip, :structurally_invalid}
    end
  end
end
