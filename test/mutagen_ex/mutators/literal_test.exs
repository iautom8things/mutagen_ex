defmodule MutagenEx.Mutators.LiteralTest do
  use ExUnit.Case, async: true

  alias MutagenEx.Mutators.Literal

  test "name is :literal" do
    assert Literal.name() == :literal
  end

  describe "match?/1" do
    test "matches booleans and the small integers 0, 1, -1" do
      assert Literal.match?(true)
      assert Literal.match?(false)
      assert Literal.match?(0)
      assert Literal.match?(1)
      assert Literal.match?(-1)
    end

    test "does not match other literals" do
      refute Literal.match?(2)
      refute Literal.match?(:atom)
      refute Literal.match?("string")
      refute Literal.match?([])
    end
  end

  describe "mutate/1" do
    test "true <-> false" do
      assert Literal.mutate(true) == false
      assert Literal.mutate(false) == true
    end

    test "0 -> 1, 1 -> 0, -1 -> 1" do
      assert Literal.mutate(0) == 1
      assert Literal.mutate(1) == 0
      assert Literal.mutate(-1) == 1
    end

    test "boolean swap is involutive" do
      assert Literal.mutate(Literal.mutate(true)) == true
      assert Literal.mutate(Literal.mutate(false)) == false
    end
  end

  describe "validate/1" do
    @tag :validate
    test ":ok for booleans and integers" do
      assert Literal.validate(true) == :ok
      assert Literal.validate(0) == :ok
      assert Literal.validate(7) == :ok
    end

    @tag :validate
    test ":skip on non-literal input" do
      assert Literal.validate(:atom) == {:skip, :structurally_invalid}
    end
  end
end
