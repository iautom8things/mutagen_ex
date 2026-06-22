defmodule MutagenEx.Mutators.PipelineTest do
  use ExUnit.Case, async: true

  alias MutagenEx.Mutators.Pipeline

  describe "name/0" do
    test "name is :pipeline" do
      assert Pipeline.name() == :pipeline
    end
  end

  describe "match?/1" do
    test "matches two-stage pipeline `a |> b() |> c()`" do
      assert Pipeline.match?(Code.string_to_quoted!("a |> b() |> c()"))
    end

    test "does not match a single-stage pipeline `a |> b()`" do
      refute Pipeline.match?(Code.string_to_quoted!("a |> b()"))
    end

    test "does not match a non-pipe expression" do
      refute Pipeline.match?(Code.string_to_quoted!("a + b"))
    end
  end

  describe "mutate/1" do
    test "swaps the two pipe stages, preserving the initial value" do
      ast = Code.string_to_quoted!("a |> b() |> c()")
      mutated = Pipeline.mutate(ast)
      # After swap: a |> c() |> b()
      assert {:|>, _, [{:|>, _, [{:a, _, _}, outer_was_inner]}, inner_was_outer]} = mutated
      assert match?({:c, _, _}, outer_was_inner)
      assert match?({:b, _, _}, inner_was_outer)
    end

    test "two-stage pipeline mutate is involutive" do
      ast = Code.string_to_quoted!("a |> b() |> c()")
      assert Pipeline.mutate(Pipeline.mutate(ast)) == ast
    end
  end

  describe "validate/1" do
    @tag :validate
    test ":ok when the two segments differ" do
      ast = Code.string_to_quoted!("a |> b() |> c()")
      assert Pipeline.validate(Pipeline.mutate(ast)) == :ok
    end

    @tag :validate
    test "{:skip, :no_op_shadowed} when the two segments are identical" do
      ast = Code.string_to_quoted!("a |> b() |> b()")
      assert Pipeline.validate(Pipeline.mutate(ast)) == {:skip, :no_op_shadowed}
    end

    @tag :validate
    test ":skip on non-pipe input" do
      assert Pipeline.validate(42) == {:skip, :structurally_invalid}
    end
  end
end
