defmodule MutagenEx.Mutators.ResultTupleTest do
  use ExUnit.Case, async: true

  alias MutagenEx.Mutators.ResultTuple

  test "name is :result_tuple" do
    assert ResultTuple.name() == :result_tuple
  end

  describe "match?/1" do
    test "matches {:ok, x}" do
      ast = Code.string_to_quoted!("{:ok, x}")
      assert ResultTuple.match?(ast)
    end

    test "matches {:error, x}" do
      ast = Code.string_to_quoted!("{:error, :bad}")
      assert ResultTuple.match?(ast)
    end

    test "does not match other 2-tuples" do
      refute ResultTuple.match?(Code.string_to_quoted!("{:noreply, state}"))
      refute ResultTuple.match?(Code.string_to_quoted!("{a, b}"))
    end

    test "does not match 3+ tuples" do
      refute ResultTuple.match?(Code.string_to_quoted!("{:ok, x, y}"))
    end
  end

  describe "mutate/1" do
    test "{:ok, x} -> {:error, x}" do
      ast = Code.string_to_quoted!("{:ok, x}")
      assert {:error, {:x, _, _}} = ResultTuple.mutate(ast)
    end

    test "{:error, x} -> {:ok, x}" do
      ast = Code.string_to_quoted!("{:error, :bad}")
      assert {:ok, :bad} = ResultTuple.mutate(ast)
    end

    test "mutate is involutive" do
      ast = Code.string_to_quoted!("{:ok, x}")
      assert ResultTuple.mutate(ResultTuple.mutate(ast)) == ast
    end
  end

  describe "validate/1" do
    @tag :validate
    test ":ok on result tuples" do
      assert ResultTuple.validate({:ok, :anything}) == :ok
      assert ResultTuple.validate({:error, :anything}) == :ok
    end

    @tag :validate
    test ":skip on non-result tuples" do
      assert ResultTuple.validate({:noreply, :state}) == {:skip, :structurally_invalid}
    end
  end
end
