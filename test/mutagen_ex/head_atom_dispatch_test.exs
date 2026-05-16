defmodule MutagenEx.HeadAtomDispatchTest do
  @moduledoc """
  Equivalence and order-preservation tests for the head-atom dispatch
  table introduced in `mutagen-wrd.25.4`.

  The dispatch table (`MutagenEx.Mutators.Dispatch`) lets the enumerator
  pre-filter the catalog by an AST node's head atom before consulting
  each mutator's `match?/1`. To be safe to deploy in the production path,
  the pre-filter must be:

    1. **Equivalent** — for every node, the set of mutators that
       `match?/1` accepts must be identical whether we asked the full
       catalog or only the dispatch-table candidates. This is the
       correctness contract from
       `mutagen.decision.static_mutator_dispatch`.
    2. **Order-preserving** — `Dispatch.mutators_for_node/1` returns a
       sub-sequence of `MutagenEx.Mutators.all/0`. Site emission order
       must be byte-identical between the legacy and head-atom paths
       (the byte-identity property of
       `mutagen.mutation_enumeration.r1`).

  Both properties are checked against a representative corpus of AST
  shapes drawn from real `lib/` source patterns we have seen during
  enumeration: arithmetic and comparison binary ops, boolean operators
  and negations, `case`/`cond`/`with` constructs, pipelines, tagged
  result tuples, bare and `__block__`-wrapped literals, function-clause
  guards, and an `if`/`else` form. If we add a new mutator or a new
  spec scenario, this corpus is the first place a coverage gap would
  surface.

  ## Test seam: `:dispatch_mode`

  `MutagenEx.MutationEnumerator.enumerate/4` accepts an internal
  `:dispatch_mode` option (`:head_atom` | `:legacy`). It is **not** a
  public API and is **not** exposed via the Mix task; it exists ONLY so
  this test can drive both paths against the same input tuple and
  compare results. Outside this test file, callers must rely on the
  default (`:head_atom`).
  """

  use ExUnit.Case, async: true

  alias MutagenEx.MutationEnumerator
  alias MutagenEx.Mutators
  alias MutagenEx.Mutators.Dispatch
  alias MutagenEx.ScopeResolver.Scope

  # --- Unit-level corpus: per-node mutator-set equivalence --------------
  #
  # For each shape, compute the set of mutators that would actually
  # match it via the legacy path (`Mutators.all/0` |> match?), then
  # assert it equals the set of mutators that `Dispatch.mutators_for_node/1`
  # returns when filtered by the same `match?`. Equality of the
  # *filtered-by-match?* sets is the correctness property; the broader
  # contract (Dispatch result is a sub-sequence of `Mutators.all/0`) is
  # checked separately below.

  defp parse!(source) do
    {:ok, ast} =
      Code.string_to_quoted(source,
        columns: true,
        token_metadata: true,
        line: 1,
        file: "corpus.ex"
      )

    ast
  end

  # Walk every node of `ast` and collect it into a flat list, mirroring
  # the order `Macro.prewalk/3` would visit them.
  defp every_node(ast) do
    {_ast, acc} =
      Macro.prewalk(ast, [], fn node, acc -> {node, [node | acc]} end)

    Enum.reverse(acc)
  end

  defp matching_mutators_via_legacy(node) do
    Mutators.all()
    |> Enum.filter(fn m -> m.match?(node) end)
  end

  defp matching_mutators_via_dispatch(node) do
    node
    |> Dispatch.mutators_for_node()
    |> Enum.filter(fn m -> m.match?(node) end)
  end

  # The corpus of source fragments. Each is parsed and exploded into
  # every constituent AST node so the test exercises both top-level
  # forms (e.g. `:with`, `:case`) and the leaf shapes the parser
  # nests inside them (e.g. `:__block__`-wrapped literals, bare
  # variables, 2-tuples). The descriptive `tag` is used in failure
  # messages so a regression points back at the shape that broke.
  @corpus [
    {"arith +", "1 + 2"},
    {"arith -", "x - y"},
    {"arith * with literals", "a * 3"},
    {"arith /", "a / b"},
    {"compare ==", "x == 0"},
    {"compare !=", "x != y"},
    {"compare <", "n < 0"},
    {"compare >=", "n >= 0"},
    {"compare >", "n > 0"},
    {"compare <=", "n <= 0"},
    {"boolean and", "x and y"},
    {"boolean or", "x or y"},
    {"boolean &&", "x && y"},
    {"boolean ||", "x || y"},
    {"boolean not", "not x"},
    {"boolean !", "!x"},
    {"literal true", "true"},
    {"literal false", "false"},
    {"literal 0", "0"},
    {"literal 1", "1"},
    {"literal -1", "-1"},
    {"with two clauses", "with {:ok, a} <- f(), {:ok, b} <- g(a), do: a + b"},
    {"with else branch", "with {:ok, x} <- f(), do: x, else: (_ -> nil)"},
    {"case two clauses", "case n do\n  0 -> :z\n  n -> n\nend"},
    {"case with guard", "case n do\n  n when n > 0 -> count_down(n - 1)\n  0 -> :done\nend"},
    {"cond two clauses", "cond do\n  x > 0 -> :pos\n  true -> :other\nend"},
    {"pipeline three stages", "x |> f() |> g() |> h()"},
    {"result_tuple ok", "{:ok, 1}"},
    {"result_tuple error", "{:error, :nope}"},
    {"if with else", "if cond?, do: a, else: b"},
    {"if without else", "if cond?, do: a"},
    {"function-clause guard",
     """
     def f(n) when is_integer(n) and n > 0 do
       n
     end
     """},
    {"anonymous function with guard clause", "fn n when n > 0 -> n end"},
    {"variable reference", "x"},
    {"function call", "foo(1, 2)"},
    {"keyword list", "[a: 1, b: 2]"},
    {"string literal", "\"hello\""},
    {"atom literal", ":atom"}
  ]

  describe "per-node equivalence (correctness of the head-atom pre-filter)" do
    for {tag, source} <- @corpus do
      @tag corpus: tag
      test "for every node in #{inspect(tag)}, dispatch filtered by match? equals legacy filtered by match?" do
        ast = parse!(unquote(source))

        for node <- every_node(ast) do
          legacy = matching_mutators_via_legacy(node)
          dispatch = matching_mutators_via_dispatch(node)

          assert legacy == dispatch,
                 "mutator-set divergence for node #{inspect(node, limit: :infinity)} " <>
                   "(corpus entry: #{inspect(unquote(tag))}).\n" <>
                   "  legacy   = #{inspect(legacy)}\n" <>
                   "  dispatch = #{inspect(dispatch)}\n" <>
                   "Either the Dispatch table is missing a head atom, or a mutator's " <>
                   "match?/1 now accepts a shape not covered by its dispatch entry."
        end
      end
    end
  end

  describe "Dispatch result shape (order-preservation and sub-sequence properties)" do
    test "Dispatch.mutators_for_node/1 returns a sub-sequence of Mutators.all/0" do
      all = Mutators.all()
      all_index = all |> Enum.with_index() |> Map.new()

      # Drive a few canonical node shapes through Dispatch and verify
      # the result is order-preserving relative to Mutators.all/0.
      # Order-preservation: for any two mutators a, b in the result,
      # if index(a) < index(b) in Mutators.all/0 then a appears before
      # b in the result. We check the stricter property that the
      # result's indices are strictly increasing.
      probes = [
        # 3-tuple shapes with known head atoms
        {:+, [], [1, 2]},
        {:with, [], [{:<-, [], [:p, :e]}, [do: :body]]},
        {:if, [], [:cond, [do: :a, else: :b]]},
        {:case, [], [:subj, [do: [{:->, [], [[:p], :r]}]]]},
        {:|>, [], [{:|>, [], [:a, :b]}, :c]},
        {:when, [], [:head, :guard]},
        # Shapes that go through `:any` only
        {:ok, :payload},
        true,
        0,
        # A `{:__block__, _, [literal]}` wrapper (Literal in `:any`,
        # plus the `:__block__` head, which has no head-specific
        # mutators).
        {:__block__, [line: 1, column: 1], [0]}
      ]

      for probe <- probes do
        result = Dispatch.mutators_for_node(probe)

        assert is_list(result),
               "Dispatch.mutators_for_node/1 must return a list, got #{inspect(result)}"

        assert Enum.all?(result, &Map.has_key?(all_index, &1)),
               "Dispatch result contains a module not in Mutators.all/0: #{inspect(result)}"

        indices = Enum.map(result, &Map.fetch!(all_index, &1))

        assert indices == Enum.sort(indices) and indices == Enum.uniq(indices),
               "Dispatch result for #{inspect(probe)} is not a strictly-ordered " <>
                 "sub-sequence of Mutators.all/0:\n  result  = #{inspect(result)}\n" <>
                 "  indices = #{inspect(indices)}"
      end
    end
  end

  # --- Integration-level corpus: end-to-end enumerator equivalence ------
  #
  # The unit-level tests above guarantee that the head-atom path and the
  # legacy path consult the same mutator set per node. The integration
  # tests run the full enumerator (`MutationEnumerator.enumerate/4`)
  # against both modes for a representative set of source files and
  # assert byte-identical output — same sites, same skips, same
  # warnings, same order. This is the property
  # `mutagen.mutation_enumeration.r1` cares about (byte-identity
  # determinism); the dispatch optimisation cannot weaken it.

  defp covered_lines(file, lines) do
    %{file => MapSet.new(lines)}
  end

  defp ast_cache_for(file, source) do
    %{file => parse!(source)}
  end

  defp scope_for(file, module, range \\ 1..1000) do
    [%Scope{file: file, line_range: range, module: module}]
  end

  @integration_corpus [
    {"sample arith module", "lib/sample.ex", SampleArith, 1..10,
     """
     defmodule SampleArith do
       def add(a, b), do: a + b
       def sub(a, b), do: a - b
       def mul(a, b), do: a * b
     end
     """},
    {"sample compare + guard", "lib/sample_compare.ex", SampleCompare, 1..15,
     """
     defmodule SampleCompare do
       def positive?(n) when is_integer(n) and n > 0, do: true
       def zero?(n), do: n == 0
       def big?(n), do: n >= 100
     end
     """},
    {"sample case_drop + with", "lib/sample_case.ex", SampleCase, 1..20,
     """
     defmodule SampleCase do
       def classify(n) do
         case n do
           0 -> :zero
           n when n > 0 -> :positive
           _ -> :negative
         end
       end

       def chain(x) do
         with {:ok, a} <- f(x),
              {:ok, b} <- g(a) do
           a + b
         end
       end
     end
     """},
    {"sample literal + pipeline", "lib/sample_pipe.ex", SamplePipe, 1..15,
     """
     defmodule SamplePipe do
       def go(x) do
         x
         |> f()
         |> g()
         |> h()
       end

       def flag, do: true

       def zero, do: 0
     end
     """},
    {"sample boolean + if/else", "lib/sample_bool.ex", SampleBool, 1..15,
     """
     defmodule SampleBool do
       def ok?(a, b), do: a and b
       def either(a, b), do: a or b
       def branch(cond?) do
         if cond?, do: :yes, else: :no
       end
     end
     """},
    {"sample result_tuple", "lib/sample_result.ex", SampleResult, 1..15,
     """
     defmodule SampleResult do
       def ok(x), do: {:ok, x}
       def err(reason), do: {:error, reason}
     end
     """}
  ]

  describe "enumerator-level equivalence (head_atom vs legacy)" do
    for {label, file, module, range, source} <- @integration_corpus do
      @tag integration: label
      test "byte-identical output for #{inspect(label)}" do
        cache = ast_cache_for(unquote(file), unquote(source))
        scopes = scope_for(unquote(file), unquote(module), unquote(Macro.escape(range)))
        # Cover all lines so coverage filtering does not mask
        # divergences. The bench fixture range is wider than any
        # source we use here, but covered_lines is conservative anyway.
        covered = covered_lines(unquote(file), Enum.to_list(1..1000))

        head_atom =
          MutationEnumerator.enumerate(cache, scopes, covered, dispatch_mode: :head_atom)

        legacy = MutationEnumerator.enumerate(cache, scopes, covered, dispatch_mode: :legacy)

        assert head_atom == legacy,
               "enumerator output diverged between :head_atom and :legacy for " <>
                 "#{inspect(unquote(label))}.\n" <>
                 "  head_atom sites = #{inspect(Enum.map(head_atom.sites, & &1.id))}\n" <>
                 "  legacy   sites = #{inspect(Enum.map(legacy.sites, & &1.id))}\n" <>
                 "  head_atom skipped = #{inspect(head_atom.skipped)}\n" <>
                 "  legacy   skipped = #{inspect(legacy.skipped)}"

        # Site order in particular is the byte-identity property.
        # Spell it out as a separate assertion so a regression names
        # exactly which property fell over.
        assert Enum.map(head_atom.sites, & &1.id) == Enum.map(legacy.sites, & &1.id),
               "site emission order diverged between :head_atom and :legacy " <>
                 "(byte-identity / mutagen.mutation_enumeration.r1)."
      end
    end

    test "head_atom mode is the default when :dispatch_mode is omitted" do
      cache =
        ast_cache_for("lib/default.ex", """
        defmodule Default do
          def f(a, b), do: a + b
        end
        """)

      scopes = scope_for("lib/default.ex", Default)
      covered = covered_lines("lib/default.ex", Enum.to_list(1..1000))

      implicit = MutationEnumerator.enumerate(cache, scopes, covered)
      explicit = MutationEnumerator.enumerate(cache, scopes, covered, dispatch_mode: :head_atom)

      assert implicit == explicit
    end

    test "an invalid :dispatch_mode raises ArgumentError" do
      cache =
        ast_cache_for("lib/bad.ex", """
        defmodule Bad do
          def f, do: :ok
        end
        """)

      scopes = scope_for("lib/bad.ex", Bad)
      covered = covered_lines("lib/bad.ex", Enum.to_list(1..1000))

      assert_raise ArgumentError, ~r/:dispatch_mode/, fn ->
        MutationEnumerator.enumerate(cache, scopes, covered, dispatch_mode: :bogus)
      end
    end
  end
end
