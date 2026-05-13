defmodule MutagenEx.Mutators.CompareTest do
  use ExUnit.Case, async: true

  alias MutagenEx.Mutators.Compare

  test "name is :compare" do
    assert Compare.name() == :compare
  end

  describe "match?/1" do
    test "matches ==, !=, <, >=, >, <=" do
      for src <- ["a == 1", "a != 1", "a < 1", "a >= 1", "a > 1", "a <= 1"] do
        assert Compare.match?(Code.string_to_quoted!(src)), "expected match on #{src}"
      end
    end

    test "does not match arithmetic or boolean" do
      for src <- ["a + 1", "a && b", "a |> f()"] do
        refute Compare.match?(Code.string_to_quoted!(src))
      end
    end
  end

  describe "mutate/1 — pair swaps" do
    test "== <-> !=" do
      assert {:!=, _, _} = Compare.mutate(Code.string_to_quoted!("a == 1"))
      assert {:==, _, _} = Compare.mutate(Code.string_to_quoted!("a != 1"))
    end

    test "< <-> >=" do
      assert {:>=, _, _} = Compare.mutate(Code.string_to_quoted!("a < 1"))
      assert {:<, _, _} = Compare.mutate(Code.string_to_quoted!("a >= 1"))
    end

    test "> <-> <=" do
      assert {:<=, _, _} = Compare.mutate(Code.string_to_quoted!("a > 1"))
      assert {:>, _, _} = Compare.mutate(Code.string_to_quoted!("a <= 1"))
    end

    test "mutate is involutive" do
      for src <- ["a == 1", "a != 1", "a < 1", "a >= 1", "a > 1", "a <= 1"] do
        ast = Code.string_to_quoted!(src)
        assert Compare.mutate(Compare.mutate(ast)) == ast
      end
    end
  end

  describe "validate/1" do
    @tag :validate
    test ":ok on matched shapes" do
      for src <- ["a == 1", "a < 1"] do
        ast = Code.string_to_quoted!(src)
        assert Compare.validate(Compare.mutate(ast)) == :ok
      end
    end

    @tag :validate
    test ":skip on non-comparison input" do
      assert Compare.validate(42) == {:skip, :structurally_invalid}
    end
  end
end
