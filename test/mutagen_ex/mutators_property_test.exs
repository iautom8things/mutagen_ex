defmodule MutagenEx.MutatorsPropertyTest do
  @moduledoc """
  Property-style tests for the catalog.

  Covers:

    * `mutagen.mutators.r5` — for mutators whose swap is symmetric (arith,
      compare, literal, result_tuple, pipeline, boolean binary swaps),
      `mutate(mutate(node)) == node`.
    * `mutagen.mutators.r6` — `Macro.to_string/1` of a `:ok`-validated swap
      round-trips through `Code.string_to_quoted/2` to a structurally
      equivalent AST.

  The property is exercised over a deterministic, seeded sample space rather
  than via `StreamData`. The catalog's input domain for each mutator is
  small enough that an explicit enumeration of representative inputs gives
  the same confidence as a random search, and avoids pulling a hex
  dependency into a fresh project (the parent epic's S0 plan flagged
  third-party deps as scope-sensitive).

  Re-introducing `StreamData` is a one-line change in `mix.exs` if a future
  ticket needs broader generation.
  """

  use ExUnit.Case, async: true

  alias MutagenEx.Mutators

  alias MutagenEx.Mutators.{
    Arith,
    Boolean,
    CaseDrop,
    Compare,
    ElseRemoval,
    GuardDrop,
    Literal,
    Pipeline,
    ResultTuple,
    WithSwap
  }

  # ---------------------------------------------------------------------------
  # mutagen.mutators.r5 — symmetric-swap invariance: mutate(mutate(x)) == x.
  # ---------------------------------------------------------------------------

  @arith_samples (for op <- ["+", "-", "*", "/"],
                      lhs <- ["a", "x", "1", "2"],
                      rhs <- ["b", "y", "3", "4"] do
                    Code.string_to_quoted!("#{lhs} #{op} #{rhs}")
                  end)

  @compare_samples (for op <- ["==", "!=", "<", ">=", ">", "<="],
                        lhs <- ["a", "1"],
                        rhs <- ["b", "2"] do
                      Code.string_to_quoted!("#{lhs} #{op} #{rhs}")
                    end)

  @boolean_binary_samples (for op <- ["and", "or", "&&", "||"],
                               lhs <- ["a", "true", "false"],
                               rhs <- ["b", "true", "false"] do
                             Code.string_to_quoted!("#{lhs} #{op} #{rhs}")
                           end)

  @result_tuple_samples [
    Code.string_to_quoted!("{:ok, x}"),
    Code.string_to_quoted!("{:error, :reason}"),
    Code.string_to_quoted!("{:ok, 0}"),
    Code.string_to_quoted!("{:error, [1, 2, 3]}")
  ]

  @pipeline_samples [
    Code.string_to_quoted!("a |> b() |> c()"),
    Code.string_to_quoted!("a |> b(1) |> c(2)"),
    Code.string_to_quoted!("1 |> Integer.to_string() |> String.reverse()")
  ]

  @tag spec: "mutagen.mutators.r5"
  test "Arith: mutate ∘ mutate == identity (r5)" do
    for ast <- @arith_samples do
      assert Arith.mutate(Arith.mutate(ast)) == ast
    end
  end

  @tag spec: "mutagen.mutators.r5"
  test "Compare: mutate ∘ mutate == identity (r5)" do
    for ast <- @compare_samples do
      assert Compare.mutate(Compare.mutate(ast)) == ast
    end
  end

  @tag spec: "mutagen.mutators.r5"
  test "Boolean (binary): mutate ∘ mutate == identity (r5)" do
    for ast <- @boolean_binary_samples do
      assert Boolean.mutate(Boolean.mutate(ast)) == ast
    end
  end

  @tag spec: "mutagen.mutators.r5"
  test "Literal (booleans): mutate ∘ mutate == identity (r5)" do
    for ast <- [true, false] do
      assert Literal.mutate(Literal.mutate(ast)) == ast
    end
  end

  @tag spec: "mutagen.mutators.r5"
  test "Literal (`__block__`-wrapped booleans): mutate ∘ mutate == identity (r5, bw mutagen-wrd.15)" do
    # Note: `:token` metadata is intentionally absent here. `mutate/1`
    # strips it on swap (see literal.ex: stale-token would make
    # `Macro.to_string` render the OLD value, breaking r6's source-
    # rendering bridge). Once stripped, subsequent swaps preserve the
    # rest of meta verbatim, so the involutive invariant holds on
    # token-less meta — which is the long-tail shape after the first
    # swap.
    meta = [line: 7, column: 5]

    for value <- [true, false] do
      ast = {:__block__, meta, [value]}
      assert Literal.mutate(Literal.mutate(ast)) == ast
    end
  end

  @tag spec: "mutagen.mutators.r5"
  test "Literal (`__block__`-wrapped 0/1): mutate ∘ mutate == identity (r5, bw mutagen-wrd.15)" do
    # See companion test above for the `:token`-absent rationale.
    meta = [line: 12, column: 3]

    for value <- [0, 1] do
      ast = {:__block__, meta, [value]}
      assert Literal.mutate(Literal.mutate(ast)) == ast
    end
  end

  test "Literal (`__block__`-wrapped, with `:token`): swap strips stale token but preserves positional meta (bw mutagen-wrd.15)" do
    # Demonstrate the rendering-bridge invariant explicitly: when `:token`
    # is present, swap drops it so the rendered source reflects the
    # swapped value rather than the original token. Positional meta
    # survives so the enumerator's attribution lines remain stable.
    meta = [token: "true", line: 7, column: 5]
    ast = {:__block__, meta, [true]}

    swapped = Literal.mutate(ast)
    assert {:__block__, swapped_meta, [false]} = swapped
    refute Keyword.has_key?(swapped_meta, :token)
    assert Keyword.get(swapped_meta, :line) == 7
    assert Keyword.get(swapped_meta, :column) == 5

    # And the rendered source is the swapped value.
    assert Macro.to_string(swapped) == "false"
  end

  @tag spec: "mutagen.mutators.r5"
  test "ResultTuple: mutate ∘ mutate == identity (r5)" do
    for ast <- @result_tuple_samples do
      assert ResultTuple.mutate(ResultTuple.mutate(ast)) == ast
    end
  end

  @tag spec: "mutagen.mutators.r5"
  test "Pipeline (two-stage): mutate ∘ mutate == identity (r5)" do
    for ast <- @pipeline_samples do
      assert Pipeline.mutate(Pipeline.mutate(ast)) == ast
    end
  end

  # ---------------------------------------------------------------------------
  # mutagen.mutators.r6 — round-trip: Macro.to_string |> Code.string_to_quoted
  # ---------------------------------------------------------------------------

  @tag spec: "mutagen.mutators.r6"
  test "Macro.to_string round-trip succeeds for every :ok-validated swap (r6)" do
    cases = [
      {@arith_samples, &Arith.match?/1, &Arith.mutate/1, &Arith.validate/1},
      {@compare_samples, &Compare.match?/1, &Compare.mutate/1, &Compare.validate/1},
      {@boolean_binary_samples, &Boolean.match?/1, &Boolean.mutate/1, &Boolean.validate/1},
      {@pipeline_samples, &Pipeline.match?/1, &Pipeline.mutate/1, &Pipeline.validate/1},
      {@result_tuple_samples, &ResultTuple.match?/1, &ResultTuple.mutate/1,
       &ResultTuple.validate/1},
      {[true, false, 0, 1], &Literal.match?/1, &Literal.mutate/1, &Literal.validate/1},
      {parsed("case x do 1 -> :one; 2 -> :two end"), &CaseDrop.match?/1, &CaseDrop.mutate/1,
       &CaseDrop.validate/1},
      {parsed("if x, do: 1, else: 2"), &ElseRemoval.match?/1, &ElseRemoval.mutate/1,
       &ElseRemoval.validate/1},
      {parsed("(foo(x) when is_binary(x)) when is_integer(x)"), &GuardDrop.match?/1,
       &GuardDrop.mutate/1, &GuardDrop.validate/1},
      {parsed("with {:ok, x} <- f(), {:ok, y} <- g(), do: {x, y}"), &WithSwap.match?/1,
       &WithSwap.mutate/1, &WithSwap.validate/1}
    ]

    assert MapSet.new(cases, fn {_, _, mutate, _} -> elem(Function.info(mutate, :module), 1) end) ==
             MapSet.new(Mutators.all())

    for {samples, matches?, mutate, validate} <- cases do
      validated =
        for ast <- samples,
            matches?.(ast),
            swapped = mutate.(ast),
            validate.(swapped) == :ok,
            do: swapped

      assert validated != [], "no valid swap for #{inspect(mutate)}"

      for swapped <- validated do
        source = Macro.to_string(swapped)

        assert {:ok, reparsed} = Code.string_to_quoted(source),
               "#{inspect(mutate)} emitted invalid source: #{source}"

        assert Mutators.normalize(reparsed) == Mutators.normalize(swapped),
               "#{inspect(mutate)} changed AST shape on round trip: #{source}"
      end
    end
  end

  defp parsed(source), do: [Code.string_to_quoted!(source)]

  # ---------------------------------------------------------------------------
  # Deterministic seeded sampling over a wider Arith domain (r5 in depth).
  # ---------------------------------------------------------------------------

  @tag spec: "mutagen.mutators.r5"
  test "Arith involution holds over a seeded sample of 100 binary expressions" do
    :rand.seed(:exsss, {1, 2, 3})

    for _ <- 1..100 do
      op = Enum.random(["+", "-", "*", "/"])
      lhs = Enum.random(["a", "b", "0", "1", "2", "x_var", "(a + b)"])
      rhs = Enum.random(["c", "d", "0", "1", "2", "y_var", "(c * d)"])
      ast = Code.string_to_quoted!("#{lhs} #{op} #{rhs}")

      if Arith.match?(ast) do
        assert Arith.mutate(Arith.mutate(ast)) == ast
      end
    end
  end
end
