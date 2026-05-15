defmodule Mix.Tasks.MutagenRenderTest do
  @moduledoc """
  Tests `Mix.Tasks.Mutagen`'s private result-rendering path via the
  `__render_result__/1` test seam.

  Specifically, asserts `mutagen.json_schema.r12` / `s9` — for each
  rendered result, `before` and `before_source` are byte-identical AND
  share the SAME underlying binary reference (`:erts_debug.same/2`),
  proving that `Macro.to_string(r.original_ast)` was computed exactly
  once and aliased into both fields. Prior to this ticket, the render
  path called `Macro.to_string(r.original_ast)` twice per result — once
  for `before` and once for `before_source` — producing two distinct
  binaries that compared equal but were not the same reference.

  Why `:erts_debug.same/2` (and not `:erlang.trace`): `Macro.to_string`
  is implemented in Elixir and the trace mechanism does not reliably
  catch every dispatch on the optimised release build. Reference
  equality, however, is a direct falsifiability test of the
  "compute-once, alias-into-both" contract — two separate
  `Macro.to_string/1` calls on the same AST return equal but
  non-same binaries; a single call aliased into both fields returns
  the same reference. The presence of the bug pattern (double-compute)
  flips this from `true` to `false`.
  """

  use ExUnit.Case, async: false

  # --------------------------------------------------------------------
  # r12: identical before/before_source binaries
  # --------------------------------------------------------------------

  describe "r12: render_result/1 aliases one Macro.to_string/1 binary into before + before_source" do
    test "before and before_source are byte-identical for every rendered result" do
      for r <- sample_results(5) do
        wire = Mix.Tasks.Mutagen.__render_result__(r)

        assert wire[:before] == wire[:before_source],
               "r12: before and before_source must be byte-identical " <>
                 "(got before=#{inspect(wire[:before])} before_source=#{inspect(wire[:before_source])})"
      end
    end

    test "before and before_source share the SAME binary reference (proves single Macro.to_string/1 call)" do
      # `:erts_debug.same/2` is the load-bearing assertion for r12: it
      # returns `true` only when both arguments are the SAME term in
      # memory. Two separate `Macro.to_string/1` calls on the same AST
      # produce binaries that compare equal under `==` but are not the
      # same reference. The render path's compute-once-and-alias
      # behaviour is the only way both fields can be `same/2`-true.
      for r <- sample_results(5) do
        wire = Mix.Tasks.Mutagen.__render_result__(r)

        assert :erts_debug.same(wire[:before], wire[:before_source]),
               "r12: before and before_source must be the SAME binary reference " <>
                 "(separate Macro.to_string/1 calls produce equal-but-distinct binaries; " <>
                 "compute-once-and-alias produces a single shared reference). " <>
                 "Got before=#{inspect(wire[:before])} before_source=#{inspect(wire[:before_source])}."
      end
    end

    test "before is byte-equal to a fresh Macro.to_string(r.original_ast)" do
      [r | _] = sample_results(1)
      wire = Mix.Tasks.Mutagen.__render_result__(r)

      assert wire[:before] == Macro.to_string(r.original_ast)
    end

    test "after is byte-equal to Macro.to_string(r.mutated_ast)" do
      [r | _] = sample_results(1)
      wire = Mix.Tasks.Mutagen.__render_result__(r)

      assert wire[:after] == Macro.to_string(r.mutated_ast)
    end

    test "before_source is NOT the same reference as after (sanity — they're different ASTs)" do
      [r | _] = sample_results(1)
      wire = Mix.Tasks.Mutagen.__render_result__(r)

      # Sanity check on the aliasing test above: `after` comes from a
      # distinct `Macro.to_string(r.mutated_ast)` call, so it CANNOT
      # be the same reference as `before_source` — even if it happened
      # to compare equal. This guards against a degenerate
      # "everything is the same binary" implementation that would
      # also pass the same/2 check above.
      refute :erts_debug.same(wire[:before_source], wire[:after]),
             "r12 sanity: before_source and after must come from distinct " <>
               "Macro.to_string/1 calls (different ASTs); they cannot share a reference"
    end
  end

  # --------------------------------------------------------------------
  # Helpers
  # --------------------------------------------------------------------

  defp sample_results(n) when is_integer(n) and n > 0 do
    for i <- 1..n do
      # Distinct ASTs per result so a buggy memoise-by-ast cache can't
      # mask a regression.
      original_ast = {:+, [], [{:a, [], nil}, i]}
      mutated_ast = {:-, [], [{:a, [], nil}, i]}

      %{
        id: "lib/foo.ex:hash#{i}:arith",
        file: "lib/foo.ex",
        line: i,
        column: 1,
        mutator: :arith,
        original_ast: original_ast,
        mutated_ast: mutated_ast,
        status: :killed,
        tainted_predecessors: false,
        warnings: []
      }
    end
  end
end
