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

  test "Arith: mutate ∘ mutate == identity (r5)" do
    for ast <- @arith_samples do
      mutator = MutagenEx.Mutators.Arith
      assert mutator.mutate(mutator.mutate(ast)) == ast
    end
  end

  test "Compare: mutate ∘ mutate == identity (r5)" do
    for ast <- @compare_samples do
      mutator = MutagenEx.Mutators.Compare
      assert mutator.mutate(mutator.mutate(ast)) == ast
    end
  end

  test "Boolean (binary): mutate ∘ mutate == identity (r5)" do
    for ast <- @boolean_binary_samples do
      mutator = MutagenEx.Mutators.Boolean
      assert mutator.mutate(mutator.mutate(ast)) == ast
    end
  end

  test "Literal (booleans): mutate ∘ mutate == identity (r5)" do
    for ast <- [true, false] do
      assert MutagenEx.Mutators.Literal.mutate(MutagenEx.Mutators.Literal.mutate(ast)) == ast
    end
  end

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
      assert MutagenEx.Mutators.Literal.mutate(MutagenEx.Mutators.Literal.mutate(ast)) == ast
    end
  end

  test "Literal (`__block__`-wrapped 0/1): mutate ∘ mutate == identity (r5, bw mutagen-wrd.15)" do
    # See companion test above for the `:token`-absent rationale.
    meta = [line: 12, column: 3]

    for value <- [0, 1] do
      ast = {:__block__, meta, [value]}
      assert MutagenEx.Mutators.Literal.mutate(MutagenEx.Mutators.Literal.mutate(ast)) == ast
    end
  end

  test "Literal (`__block__`-wrapped, with `:token`): swap strips stale token but preserves positional meta (bw mutagen-wrd.15)" do
    # Demonstrate the rendering-bridge invariant explicitly: when `:token`
    # is present, swap drops it so the rendered source reflects the
    # swapped value rather than the original token. Positional meta
    # survives so the enumerator's attribution lines remain stable.
    meta = [token: "true", line: 7, column: 5]
    ast = {:__block__, meta, [true]}

    swapped = MutagenEx.Mutators.Literal.mutate(ast)
    assert {:__block__, swapped_meta, [false]} = swapped
    refute Keyword.has_key?(swapped_meta, :token)
    assert Keyword.get(swapped_meta, :line) == 7
    assert Keyword.get(swapped_meta, :column) == 5

    # And the rendered source is the swapped value.
    assert Macro.to_string(swapped) == "false"
  end

  test "ResultTuple: mutate ∘ mutate == identity (r5)" do
    for ast <- @result_tuple_samples do
      mutator = MutagenEx.Mutators.ResultTuple
      assert mutator.mutate(mutator.mutate(ast)) == ast
    end
  end

  test "Pipeline (two-stage): mutate ∘ mutate == identity (r5)" do
    for ast <- @pipeline_samples do
      mutator = MutagenEx.Mutators.Pipeline
      assert mutator.mutate(mutator.mutate(ast)) == ast
    end
  end

  # ---------------------------------------------------------------------------
  # mutagen.mutators.r6 — round-trip: Macro.to_string |> Code.string_to_quoted
  # ---------------------------------------------------------------------------

  test "Macro.to_string round-trip succeeds for every :ok-validated swap (r6)" do
    cases =
      [
        {MutagenEx.Mutators.Arith, @arith_samples},
        {MutagenEx.Mutators.Compare, @compare_samples},
        {MutagenEx.Mutators.Boolean, @boolean_binary_samples},
        {MutagenEx.Mutators.Pipeline, @pipeline_samples},
        {MutagenEx.Mutators.ResultTuple, @result_tuple_samples}
      ]

    for {mutator, samples} <- cases, ast <- samples do
      if mutator.match?(ast) do
        swapped = mutator.mutate(ast)

        if mutator.validate(swapped) == :ok do
          source = Macro.to_string(swapped)

          assert {:ok, reparsed} = Code.string_to_quoted(source),
                 "round-trip failed for #{inspect(mutator)} on #{Macro.to_string(ast)} -> #{source}"

          # Structural equality after stripping positional metadata. The reparse
          # introduces fresh :line / :column entries.
          assert Mutators.normalize(reparsed) == Mutators.normalize(swapped),
                 "round-trip changed AST structure for #{inspect(mutator)} on #{source}"
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Deterministic seeded sampling over a wider Arith domain (r5 in depth).
  # ---------------------------------------------------------------------------

  test "Arith involution holds over a seeded sample of 100 binary expressions" do
    :rand.seed(:exsss, {1, 2, 3})

    for _ <- 1..100 do
      op = Enum.random(["+", "-", "*", "/"])
      lhs = Enum.random(["a", "b", "0", "1", "2", "x_var", "(a + b)"])
      rhs = Enum.random(["c", "d", "0", "1", "2", "y_var", "(c * d)"])
      ast = Code.string_to_quoted!("#{lhs} #{op} #{rhs}")

      if MutagenEx.Mutators.Arith.match?(ast) do
        assert MutagenEx.Mutators.Arith.mutate(MutagenEx.Mutators.Arith.mutate(ast)) == ast
      end
    end
  end
end
