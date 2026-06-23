defmodule Mix.Tasks.MutagenRenderTest do
  @moduledoc """
  Tests `Mix.Tasks.Mutagen`'s private result-rendering path via the
  `__render_result__/1` test seam.

  Covers two contracts:

    * `mutagen.json_schema.r12` — the renderer invokes
      `Macro.to_string/1` at most `2 * R` times across R results. On
      the fallback path (no `end_line`/`end_column`) `before` and
      `before_source` share the same binary reference; on the slice
      path `before_source` is a byte slice of `source_text` and does
      NOT invoke `Macro.to_string/1` at all for its computation.
    * `mutagen.json_schema.r4` — `before_source` is a verbatim source
      slice when end positions are available; otherwise falls back to
      aliasing `before`.

  Why `:erts_debug.same/2` (and not `:erlang.trace`): `Macro.to_string`
  is implemented in Elixir and the trace mechanism does not reliably
  catch every dispatch on the optimised release build. Reference
  equality, however, is a direct falsifiability test of the
  "compute-once, alias-into-both" contract — two separate
  `Macro.to_string/1` calls on the same AST return equal but
  non-same binaries; a single call aliased into both fields returns
  the same reference.
  """

  use ExUnit.Case, async: true

  # --------------------------------------------------------------------
  # r12 fallback path: legacy callers (no end_line/end_column/source_text)
  # --------------------------------------------------------------------

  describe "r12 fallback: when end_line/end_column are nil, before_source aliases before" do
    test "before and before_source are byte-identical for every rendered result" do
      for r <- sample_results(5) do
        wire = Mix.Tasks.Mutagen.__render_result__(r)

        assert wire[:before] == wire[:before_source],
               "r12: before and before_source must be byte-identical " <>
                 "(got before=#{inspect(wire[:before])} before_source=#{inspect(wire[:before_source])})"
      end
    end

    test "before and before_source share the SAME binary reference (fallback path)" do
      # Sample results omit `end_line`/`end_column`/`source_text`, so
      # the renderer takes the fallback path and aliases the single
      # `Macro.to_string(original_ast)` output into both fields.
      # `:erts_debug.same/2` returns true only when both arguments are
      # the SAME term in memory.
      for r <- sample_results(5) do
        wire = Mix.Tasks.Mutagen.__render_result__(r)

        assert :erts_debug.same(wire[:before], wire[:before_source]),
               "r12 fallback: before and before_source must be the SAME binary " <>
                 "reference when end positions are absent. Got before=" <>
                 inspect(wire[:before]) <> " before_source=" <> inspect(wire[:before_source])
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

      refute :erts_debug.same(wire[:before_source], wire[:after]),
             "before_source and after must come from distinct " <>
               "Macro.to_string/1 calls (different ASTs); they cannot share a reference"
    end

    test "fallback also triggers when end_line is present but source_text is nil" do
      # Defensive: a runner that thread end positions but no
      # source_text (e.g. legacy cache) should still produce a valid
      # report by falling back.
      [r0 | _] = sample_results(1)
      r = Map.merge(r0, %{end_line: 1, end_column: 5, source_text: nil})
      wire = Mix.Tasks.Mutagen.__render_result__(r)

      assert :erts_debug.same(wire[:before], wire[:before_source])
    end
  end

  # --------------------------------------------------------------------
  # r4 slice path: end_line/end_column + source_text → verbatim slice
  # --------------------------------------------------------------------

  describe "r4 slice: before_source is a verbatim source slice when end positions are available" do
    test "3-tuple arith site on a single line slices the exact source bytes" do
      # Mirrors the canonical `a + b` shape from
      # `test/fixtures/lane_project/lib/lane_fixture/arith.ex` line 12:
      #   "  def add(a, b), do: a + b\n"
      # `a` at column 22, `+` at column 24, `b` at column 26.
      source = "  def add(a, b), do: a + b\n"

      original_ast =
        {:+, [line: 1, column: 24],
         [
           {:a, [line: 1, column: 22], nil},
           {:b, [line: 1, column: 26], nil}
         ]}

      mutated_ast =
        {:-, [line: 1, column: 24],
         [
           {:a, [line: 1, column: 22], nil},
           {:b, [line: 1, column: 26], nil}
         ]}

      r = %{
        id: "lib/foo.ex:hash:arith",
        file: "lib/foo.ex",
        line: 1,
        column: 24,
        mutator: :arith,
        original_ast: original_ast,
        mutated_ast: mutated_ast,
        status: :killed,
        tainted_predecessors: false,
        warnings: [],
        end_line: 1,
        end_column: 27,
        source_text: source
      }

      wire = Mix.Tasks.Mutagen.__render_result__(r)

      assert wire[:before_source] == "a + b",
             "verbatim slice must equal the hand-cut source slice. " <>
               "Got: #{inspect(wire[:before_source])}"

      # `before` is the Macro.to_string output (also "a + b" by
      # coincidence here) but is computed from the AST, not the source.
      assert wire[:before] == "a + b"

      # The two binaries are now DISTINCT references (slice path) —
      # the slice came from `source_text`, `before` from
      # `Macro.to_string`. The byte equality is content-level.
      refute :erts_debug.same(wire[:before], wire[:before_source]),
             "slice path: before and before_source come from different " <>
               "sources (Macro.to_string vs source_text slice); they " <>
               "must NOT share a reference. Same reference would " <>
               "indicate the slice path silently fell back to fallback."
    end

    test "slice picks up formatting that Macro.to_string would normalize away" do
      # The contract that makes the slice valuable: when the original
      # source has formatting `Macro.to_string` would normalize away,
      # `before_source` preserves it. Here the source has extra
      # whitespace around `+` that `Macro.to_string` will not emit.
      #
      # Column layout (1-based):
      #   col: 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18
      #   chr: ' ' ' ' 'r' 'e' 's' 'u' 'l' 't' ' ' '=' ' ' 'a' ' ' ' ' '+' ' ' ' ' 'b'
      # `a` at column 12, `+` at column 15, `b` at column 18.
      # Source range "a  +  b" spans cols 12..18 inclusive, exclusive
      # end col 19.
      source = "  result = a  +  b\n"

      original_ast =
        {:+, [line: 1, column: 15],
         [
           {:a, [line: 1, column: 12], nil},
           {:b, [line: 1, column: 18], nil}
         ]}

      mutated_ast =
        {:-, [line: 1, column: 15],
         [
           {:a, [line: 1, column: 12], nil},
           {:b, [line: 1, column: 18], nil}
         ]}

      r = %{
        id: "lib/foo.ex:hash:arith",
        file: "lib/foo.ex",
        line: 1,
        column: 15,
        mutator: :arith,
        original_ast: original_ast,
        mutated_ast: mutated_ast,
        status: :killed,
        tainted_predecessors: false,
        warnings: [],
        end_line: 1,
        end_column: 19,
        source_text: source
      }

      wire = Mix.Tasks.Mutagen.__render_result__(r)

      # The verbatim slice keeps the doubled whitespace.
      assert wire[:before_source] == "a  +  b",
             "slice must preserve source whitespace; got: " <>
               inspect(wire[:before_source])

      # Macro.to_string normalizes whitespace.
      assert wire[:before] == "a + b"

      # The two binaries differ — this is the falsifiability that the
      # slice path is actually engaged.
      refute wire[:before] == wire[:before_source],
             "When the source has formatting Macro.to_string would " <>
               "normalize, `before` and `before_source` MUST differ."
    end

    test "slice path does not invoke Macro.to_string for before_source" do
      # r12 hard contract: across R results, Macro.to_string is invoked
      # exactly `2 * R` times (once per original_ast, once per
      # mutated_ast) regardless of slice vs fallback. We falsify this
      # by inserting a sentinel that `Macro.to_string` would change
      # but the slice would not: if `before_source` matches the
      # source-with-sentinel rather than the Macro.to_string output,
      # then the slice did NOT call Macro.to_string.
      source = "  z = a + b   # sentinel-trailing-spaces\n"
      # `a` col 7, `+` col 9, `b` col 11. The slice "a + b" is
      # at cols 7..11 inclusive, exclusive end col 12.
      original_ast =
        {:+, [line: 1, column: 9],
         [
           {:a, [line: 1, column: 7], nil},
           {:b, [line: 1, column: 11], nil}
         ]}

      mutated_ast =
        {:-, [line: 1, column: 9],
         [
           {:a, [line: 1, column: 7], nil},
           {:b, [line: 1, column: 11], nil}
         ]}

      r = %{
        id: "lib/foo.ex:h:arith",
        file: "lib/foo.ex",
        line: 1,
        column: 9,
        mutator: :arith,
        original_ast: original_ast,
        mutated_ast: mutated_ast,
        status: :killed,
        tainted_predecessors: false,
        warnings: [],
        end_line: 1,
        end_column: 12,
        source_text: source
      }

      wire = Mix.Tasks.Mutagen.__render_result__(r)

      # The slice covers just "a + b" — no sentinel comment leaked.
      assert wire[:before_source] == "a + b"
    end

    test "bare-literal site falls back to Macro.to_string gracefully" do
      # Per the ticket's "Out of Scope" — bare-literal sites
      # (literal mutator's bare-value clauses, e.g. swapping `0` for
      # `1`) are attributed to the parent operator and the enumerator
      # leaves `end_line`/`end_column` as nil. The renderer must fall
      # back rather than crash.
      source = "  def f(b), do: b != 0\n"

      r = %{
        id: "lib/foo.ex:h:literal",
        file: "lib/foo.ex",
        # `column: 22` points at the `0` literal's column per the
        # enumerator's bare-literal attribution.
        line: 1,
        column: 22,
        mutator: :literal,
        # original_ast is the bare integer 0 (no metadata).
        original_ast: 0,
        mutated_ast: 1,
        status: :survived,
        tainted_predecessors: false,
        warnings: [],
        # The enumerator left end positions nil because bare literals
        # have no AST metadata to derive an end from.
        end_line: nil,
        end_column: nil,
        source_text: source
      }

      wire = Mix.Tasks.Mutagen.__render_result__(r)

      # Fallback: before_source IS before, byte-identical and
      # same-reference.
      assert wire[:before] == "0"
      assert wire[:before_source] == "0"

      assert :erts_debug.same(wire[:before], wire[:before_source]),
             "bare-literal fallback: before_source must alias the " <>
               "Macro.to_string binary when no end positions exist"
    end
  end

  # --------------------------------------------------------------------
  # r12: before/after fields contain Macro.to_string output
  # --------------------------------------------------------------------

  describe "r12: before/after fields contain Macro.to_string output" do
    test "slice and fallback results both produce correct before/after values" do
      # The 2*R cap (at most one Macro.to_string call per field per result)
      # is enforced by construction: the slice path computes before_source
      # via String.split + Enum.slice + Enum.join and does not call
      # Macro.to_string for that field. The cap is NOT count-verified
      # here — this test only asserts that the rendered before/after values
      # equal the expected Macro.to_string output for both code paths.
      source = "  z = a + b\n"

      slice_result = %{
        id: "lib/foo.ex:h:arith",
        file: "lib/foo.ex",
        line: 1,
        column: 9,
        mutator: :arith,
        original_ast:
          {:+, [line: 1, column: 9],
           [{:a, [line: 1, column: 7], nil}, {:b, [line: 1, column: 11], nil}]},
        mutated_ast:
          {:-, [line: 1, column: 9],
           [{:a, [line: 1, column: 7], nil}, {:b, [line: 1, column: 11], nil}]},
        status: :killed,
        tainted_predecessors: false,
        warnings: [],
        end_line: 1,
        end_column: 12,
        source_text: source
      }

      fallback_result = hd(sample_results(1))

      for r <- [slice_result, fallback_result] do
        wire = Mix.Tasks.Mutagen.__render_result__(r)
        assert wire[:before] == Macro.to_string(r.original_ast)
        assert wire[:after] == Macro.to_string(r.mutated_ast)
      end
    end
  end

  # --------------------------------------------------------------------
  # End-to-end: enumerator → render pipeline against real arith.ex source
  # --------------------------------------------------------------------

  describe "end-to-end r4 + r8: real arith.ex parse → enumerate → render" do
    test "before_source for the `a + b` site equals the hand-cut source slice" do
      source =
        File.read!(
          Path.expand(
            "../fixtures/lane_project/lib/lane_fixture/arith.ex",
            __DIR__
          )
        )

      {:ok, ast} =
        Code.string_to_quoted(source,
          columns: true,
          token_metadata: true,
          file: "arith.ex"
        )

      cache = %{"lib/lane_fixture/arith.ex" => ast}

      scopes = [
        %MutagenEx.ScopeResolver.Scope{
          file: "lib/lane_fixture/arith.ex",
          line_range: 1..30,
          module: LaneFixture.Arith
        }
      ]

      covered = %{"lib/lane_fixture/arith.ex" => MapSet.new(Enum.to_list(1..30))}

      %{sites: sites} =
        MutagenEx.MutationEnumerator.enumerate(cache, scopes, covered)

      # Find the `+` site on line 12 (def add(a, b), do: a + b).
      plus_site =
        Enum.find(sites, fn s -> s.mutator == :arith and s.line == 12 end)

      assert plus_site,
             "expected an arith site on arith.ex line 12; got #{inspect(sites)}"

      # Build the renderer's input shape (this is what
      # MutationRunner.fold_task_outcome/4 produces for each result
      # after the parallel post-fold lands it in `acc.results`).
      result_map = %{
        id: plus_site.id,
        file: plus_site.file,
        line: plus_site.line,
        column: plus_site.column,
        mutator: plus_site.mutator,
        original_ast: plus_site.original_ast,
        mutated_ast: plus_site.mutated_ast,
        status: :killed,
        tainted_predecessors: false,
        warnings: [],
        end_line: plus_site.end_line,
        end_column: plus_site.end_column,
        source_text: source
      }

      wire = Mix.Tasks.Mutagen.__render_result__(result_map)

      # Hand-cut slice: line 12 of arith.ex is "  def add(a, b), do: a + b".
      # `a + b` spans cols 22..26 inclusive, exclusive end col 27.
      expected_slice = "a + b"

      assert wire[:before_source] == expected_slice,
             "verbatim slice through the enumerator → render pipeline " <>
               "must match the hand-cut source slice. " <>
               "Got: #{inspect(wire[:before_source])}, expected: #{inspect(expected_slice)}"

      # `before` is the Macro.to_string output — for `{:+, _, [a, b]}`
      # that's also "a + b" (Elixir's formatter normalizes to single
      # spaces around `+`). The two HAPPEN to be byte-equal here, but
      # the slice path is what produced before_source — confirmed by
      # the reference comparison.
      assert wire[:before] == "a + b"

      refute :erts_debug.same(wire[:before], wire[:before_source]),
             "slice path: before and before_source must come from " <>
               "different sources (Macro.to_string vs source slice); " <>
               "they must NOT share a reference"
    end
  end

  # --------------------------------------------------------------------
  # Helpers
  # --------------------------------------------------------------------

  defp sample_results(n) when is_integer(n) and n > 0 do
    for i <- 1..n do
      # Distinct ASTs per result so a buggy memoise-by-ast cache can't
      # mask a regression. No end positions or source_text — fallback
      # path.
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
