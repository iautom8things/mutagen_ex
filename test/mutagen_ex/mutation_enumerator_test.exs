defmodule MutagenEx.MutationEnumeratorTest do
  @moduledoc """
  Unit tests for `MutagenEx.MutationEnumerator` covering the six scenarios
  of `mutagen.mutation_enumeration` (`s1`-`s6`) and the corresponding
  requirements (`r1`-`r6`).

  Each test sets up its inputs as plain in-memory values — there is no
  disk I/O. The AST cache is a synthetic `%{file => ast}` map; the
  `covered_lines` argument is a `%{file => MapSet}` map; the scope record
  list comes from hand-built `%MutagenEx.ScopeResolver.Scope{}` structs.
  This is the test-side enforcement of r6 (no source-file re-reads from
  the enumerator).
  """

  use ExUnit.Case, async: true

  alias MutagenEx.MutationEnumerator
  alias MutagenEx.MutationEnumerator.Site
  alias MutagenEx.ScopeResolver.Scope

  # Build the `%{file => ast}` map by parsing a single synthetic source
  # string. The line numbers in the AST are real because we let
  # `Code.string_to_quoted/2` populate them.
  defp ast_cache(file, source) do
    {:ok, ast} = Code.string_to_quoted(source, columns: true, line: 1, file: file)
    %{file => ast}
  end

  defp covered_lines(file, lines) do
    %{file => MapSet.new(lines)}
  end

  defp scope(file, module, range \\ 1..1000) do
    %Scope{file: file, line_range: range, module: module}
  end

  describe "scenario s1 — determinism (mutagen.mutation_enumeration.r1)" do
    @tag :determinism
    test "the same inputs produce byte-identical site lists across two runs" do
      source = """
      defmodule Sample do
        def f(x), do: x + 1
        def g(x), do: x * 2
      end
      """

      cache = ast_cache("lib/sample.ex", source)
      scopes = [scope("lib/sample.ex", Sample)]
      covered = covered_lines("lib/sample.ex", [1, 2, 3, 4])

      r1 = MutationEnumerator.enumerate(cache, scopes, covered)
      r2 = MutationEnumerator.enumerate(cache, scopes, covered)

      assert r1 == r2
      assert is_list(r1.sites)
      assert length(r1.sites) >= 2

      # IDs and order match position-by-position
      ids1 = Enum.map(r1.sites, & &1.id)
      ids2 = Enum.map(r2.sites, & &1.id)
      assert ids1 == ids2
    end

    test "determinism holds across 10 consecutive runs" do
      source = """
      defmodule Repeated do
        def add(a, b), do: a + b
        def sub(a, b), do: a - b
        def mul(a, b), do: a * b
      end
      """

      cache = ast_cache("lib/repeated.ex", source)
      scopes = [scope("lib/repeated.ex", Repeated)]
      covered = covered_lines("lib/repeated.ex", [1, 2, 3, 4, 5])

      runs = for _ <- 1..10, do: MutationEnumerator.enumerate(cache, scopes, covered)

      [first | rest] = runs

      for run <- rest do
        assert run == first
      end
    end
  end

  describe "scenario s2 — covered_lines filtering (mutagen.mutation_enumeration.r2)" do
    @tag :filtering
    test "nodes whose line is outside covered_lines are filtered before validate/1" do
      # Three arith ops on three different source lines. The arith mutator
      # would happily produce a site for each; only the covered lines
      # should yield sites.
      source = """
      defmodule Foo do
        def a(x), do: x + 1
        def b(x), do: x - 2
        def c(x), do: x * 3
      end
      """

      cache = ast_cache("lib/foo.ex", source)
      scopes = [scope("lib/foo.ex", Foo)]

      # Cover the `def a` (line 2) and `def b` (line 3) lines; leave the
      # `def c` line (4) uncovered.
      covered = covered_lines("lib/foo.ex", [2, 3])

      result = MutationEnumerator.enumerate(cache, scopes, covered)

      # Two arith sites expected — one for each covered binary op. The
      # uncovered op produces NO site (not a skip — filtered out
      # entirely, per r2).
      arith_sites = Enum.filter(result.sites, &(&1.mutator == :arith))
      assert length(arith_sites) == 2

      lines = arith_sites |> Enum.map(& &1.line) |> Enum.sort()
      assert lines == [2, 3]

      # No skip entries for the uncovered line — it was filtered before
      # validate ran.
      assert Enum.all?(result.skipped, fn s -> s.mutator != :arith or s.file != "lib/foo.ex" end)
    end

    @tag :filtering
    test "uncovered with-chain is filtered before WithSwap.validate is consulted (r2 ordering)" do
      # This is the load-bearing test for r2's ORDERING clause: "filtered
      # out BEFORE `validate/1` is consulted". A flipped filter/validate
      # order would route the with-chain through `WithSwap.validate/1`,
      # which returns `{:skip, :bound_var_used_before_binding}` for this
      # exact shape (g(a) references `a` before the swap would have bound
      # it — see mutagen.mutators.s2). That would add a with_swap entry to
      # `result.skipped`. With the contract honored, the uncovered line is
      # filtered before validate runs, so NO skip entry appears.
      source = """
      defmodule Ordering do
        def covered_op(x), do: x + 1
        def uncovered_with do
          with {:ok, a} <- f(), {:ok, b} <- g(a) do
            a + b
          end
        end
      end
      """

      cache = ast_cache("lib/ordering.ex", source)
      scopes = [scope("lib/ordering.ex", Ordering)]
      # Cover the arith line (2) but NOT line 4, where the `with` keyword
      # lives. If the filter ran AFTER validate/1, the with node would
      # route through WithSwap.validate and add a skip entry. The
      # filter-before-validate contract (r2) means no with_swap skip entry
      # should exist for this file.
      covered = covered_lines("lib/ordering.ex", [2])

      result = MutationEnumerator.enumerate(cache, scopes, covered)

      with_swap_skips =
        Enum.filter(result.skipped, fn s ->
          s.mutator == :with_swap and s.file == "lib/ordering.ex"
        end)

      assert with_swap_skips == [],
             "Expected no with_swap skip entry (filter must run before validate/1), got: #{inspect(with_swap_skips)}"

      # Belt and suspenders: the covered arith op still produces its site,
      # so the scope is non-empty and we're observing real enumeration
      # (not a vacuous pass from short-circuiting).
      assert Enum.any?(result.sites, &(&1.mutator == :arith and &1.line == 2))
    end

    test "fully uncovered scope produces no arith sites and a no-mutation-candidates warning" do
      source = """
      defmodule Foo do
        def a(x), do: x + 1
      end
      """

      cache = ast_cache("lib/foo.ex", source)
      scopes = [scope("lib/foo.ex", Foo)]
      covered = covered_lines("lib/foo.ex", [])

      result = MutationEnumerator.enumerate(cache, scopes, covered)

      assert result.sites == []
      assert {:no_mutation_candidates, Foo} in result.warnings
    end
  end

  describe "scenario s3 — skip tracking (mutagen.mutation_enumeration.r3)" do
    @tag :filtering
    test "a with_swap site that validate/1 rejects appears in `skipped`, NOT in `sites`" do
      # The classic bound-var-used-before-binding shape from
      # mutagen.mutators.s2: g(a) references `a` before the swap would
      # have bound it.
      source = """
      defmodule Withy do
        def run do
          with {:ok, a} <- f(), {:ok, b} <- g(a) do
            a + b
          end
        end
      end
      """

      cache = ast_cache("lib/withy.ex", source)
      scopes = [scope("lib/withy.ex", Withy)]
      # Cover every line so the with site is not filtered by coverage.
      covered = covered_lines("lib/withy.ex", Enum.to_list(1..20))

      result =
        MutationEnumerator.enumerate(cache, scopes, covered,
          mutators: [MutagenEx.Mutators.WithSwap]
        )

      assert result.sites == []
      assert length(result.skipped) == 1
      [skipped] = result.skipped
      assert skipped.reason == :bound_var_used_before_binding
      assert skipped.mutator == :with_swap
      assert skipped.file == "lib/withy.ex"
      assert skipped.site_id =~ ~r/^lib\/withy\.ex:\d+:with_swap$/
    end

    test "skipped entries do NOT contribute to the sites list" do
      # The test above also asserts result.sites == []; this test makes
      # the contract crisper by mixing a site that validates with one
      # that doesn't.
      source = """
      defmodule Mixed do
        def good(x), do: x + 1
        def bad do
          with {:ok, a} <- f(), {:ok, b} <- g(a) do
            a + b
          end
        end
      end
      """

      cache = ast_cache("lib/mixed.ex", source)
      scopes = [scope("lib/mixed.ex", Mixed)]
      covered = covered_lines("lib/mixed.ex", Enum.to_list(1..20))

      result = MutationEnumerator.enumerate(cache, scopes, covered)

      # The skipped with_swap site is recorded.
      with_skips =
        Enum.filter(result.skipped, fn s ->
          s.mutator == :with_swap and s.reason == :bound_var_used_before_binding
        end)

      assert length(with_skips) == 1

      # And the arith mutation for `x + 1` is still a regular site.
      assert Enum.any?(result.sites, fn s ->
               s.mutator == :arith and s.file == "lib/mixed.ex"
             end)
    end
  end

  describe "scenario s4 — multi-module file (mutagen.mutation_enumeration.r4)" do
    test "enumeration walks only the in-scope module's defmodule subtree" do
      source = """
      defmodule Mod.A do
        def f(x), do: x + 1
      end

      defmodule Mod.B do
        def g(x), do: x * 2
      end
      """

      cache = ast_cache("lib/multi.ex", source)

      # Scope record targets ONLY Mod.A.
      scopes = [scope("lib/multi.ex", Mod.A)]
      covered = covered_lines("lib/multi.ex", Enum.to_list(1..20))

      result = MutationEnumerator.enumerate(cache, scopes, covered)

      # Every site's hash must come from a node inside Mod.A's body.
      # Mod.B has a `*` arith node we want to verify is NOT in the
      # output. We expect exactly one arith site (`x + 1` from Mod.A).
      arith_sites = Enum.filter(result.sites, &(&1.mutator == :arith))
      assert length(arith_sites) == 1

      # The one site's line corresponds to Mod.A's `def f` (line 2),
      # not Mod.B's `def g` (line 6).
      [site] = arith_sites
      assert site.line == 2

      # Belt and suspenders: compute the hash of Mod.B's `*` node and
      # confirm it never appears in the output's IDs.
      {:ok, mod_b_ast} =
        Code.string_to_quoted("defmodule Mod.B do\n  def g(x), do: x * 2\nend",
          columns: true,
          line: 1
        )

      {_, mod_b_arith_nodes} =
        Macro.prewalk(mod_b_ast, [], fn
          {op, _, [_, _]} = node, acc when op in [:+, :-, :*, :/] ->
            {node, [node | acc]}

          node, acc ->
            {node, acc}
        end)

      mod_b_hashes = Enum.map(mod_b_arith_nodes, &MutagenEx.Mutators.ast_hash/1)

      site_hashes =
        Enum.map(arith_sites, fn s ->
          [_file, hash, _name] = String.split(s.id, ":")
          String.to_integer(hash)
        end)

      assert Enum.all?(mod_b_hashes, &(&1 not in site_hashes))
    end
  end

  describe "scenario s5 — behaviour-only module yields a warning (mutagen.mutation_enumeration.r5)" do
    test "scoped module with only @callback declarations returns no sites and warns" do
      source = """
      defmodule Contract do
        @callback handle(any) :: any
      end
      """

      cache = ast_cache("lib/contract.ex", source)
      scopes = [scope("lib/contract.ex", Contract)]
      covered = covered_lines("lib/contract.ex", Enum.to_list(1..10))

      result = MutationEnumerator.enumerate(cache, scopes, covered)

      assert result.sites == []
      assert result.skipped == []
      assert {:no_mutation_candidates, Contract} in result.warnings

      # r5 exclusivity: a non-empty scope (Sample has two arith ops on
      # covered lines) must NOT receive the no_mutation_candidates
      # warning. Gates against indiscriminate warning emission — a
      # regression that emitted this for every scope would still pass
      # the assertion above.
      non_empty_source = """
      defmodule Sample do
        def f(x), do: x + 1
        def g(x), do: x * 2
      end
      """

      non_empty_cache = ast_cache("lib/sample.ex", non_empty_source)
      non_empty_scopes = [scope("lib/sample.ex", Sample)]
      non_empty_covered = covered_lines("lib/sample.ex", [1, 2, 3, 4])

      non_empty_result =
        MutationEnumerator.enumerate(non_empty_cache, non_empty_scopes, non_empty_covered)

      assert {:no_mutation_candidates, Sample} not in non_empty_result.warnings,
             "no_mutation_candidates warning must not fire on non-empty scopes; got warnings: #{inspect(non_empty_result.warnings)}"
    end
  end

  describe "scenario s6 — no source-file reads (mutagen.mutation_enumeration.r6)" do
    test "enumeration does not call File.read or Code.require_file" do
      # We can't directly observe "no I/O" without a tracer, but the
      # contract is enforceable structurally: the AST cache passed in is
      # the only AST source. We verify this two ways:
      #
      #   1. The enumerator works when given a fabricated AST whose
      #      `:file` meta points at a path that does NOT exist on disk.
      #      If the implementation tried to re-read from `:file`, this
      #      would crash with `File.Error`.
      #
      #   2. Providing a cache for a path that doesn't exist on disk
      #      produces sites whose `:file` field matches the cache key.
      source = """
      defmodule Synthetic do
        def add(x), do: x + 1
      end
      """

      synthetic_path = "/definitely/does/not/exist/lib/synthetic.ex"
      refute File.exists?(synthetic_path)

      cache = ast_cache(synthetic_path, source)
      scopes = [scope(synthetic_path, Synthetic)]
      covered = covered_lines(synthetic_path, Enum.to_list(1..5))

      # Must not raise.
      result = MutationEnumerator.enumerate(cache, scopes, covered)

      assert length(result.sites) >= 1
      assert Enum.all?(result.sites, &(&1.file == synthetic_path))
    end
  end

  describe "site shape (`mutagen.mutators.r3` plumbed through enumeration)" do
    test "every emitted site has the full `Site` struct fields populated" do
      source = """
      defmodule Shape do
        def f(x), do: x + 1
      end
      """

      cache = ast_cache("lib/shape.ex", source)
      scopes = [scope("lib/shape.ex", Shape)]
      covered = covered_lines("lib/shape.ex", Enum.to_list(1..5))

      result = MutationEnumerator.enumerate(cache, scopes, covered)

      assert [%Site{} | _] = result.sites

      for site <- result.sites do
        assert is_binary(site.id)
        assert site.id =~ ~r/^lib\/shape\.ex:\d+:[a-z_]+$/
        assert site.file == "lib/shape.ex"
        assert is_integer(site.line) and site.line >= 1
        assert is_integer(site.column) and site.column >= 1
        assert is_atom(site.mutator)
        assert site.original_ast != site.mutated_ast
      end
    end

    test "ordering: scope records are walked in input order" do
      # Two scopes pointing at the same file but different modules.
      source = """
      defmodule First do
        def f(x), do: x + 1
      end

      defmodule Second do
        def g(x), do: x - 1
      end
      """

      cache = ast_cache("lib/two.ex", source)
      covered = covered_lines("lib/two.ex", Enum.to_list(1..10))

      r_first_then_second =
        MutationEnumerator.enumerate(
          cache,
          [scope("lib/two.ex", First), scope("lib/two.ex", Second)],
          covered
        )

      r_second_then_first =
        MutationEnumerator.enumerate(
          cache,
          [scope("lib/two.ex", Second), scope("lib/two.ex", First)],
          covered
        )

      # Same site SET, different ORDER: First's sites come first when
      # scoped First-then-Second.
      assert MapSet.new(r_first_then_second.sites) ==
               MapSet.new(r_second_then_first.sites)

      # Filter to arith only so the ordering check stays load-bearing on
      # the cross-scope ordering contract regardless of how many literal
      # sites the bare-literal coverage path (bw mutagen-wrd.16) admits.
      arith_first_then_second =
        Enum.filter(r_first_then_second.sites, &(&1.mutator == :arith))

      arith_second_then_first =
        Enum.filter(r_second_then_first.sites, &(&1.mutator == :arith))

      assert length(arith_first_then_second) == 2
      assert length(arith_second_then_first) == 2

      # The lines distinguish them: First's def f is line 2, Second's
      # def g is line 6.
      [line_a, line_b] = Enum.map(arith_first_then_second, & &1.line)
      assert line_a == 2
      assert line_b == 6

      [line_a2, line_b2] = Enum.map(arith_second_then_first, & &1.line)
      assert line_a2 == 6
      assert line_b2 == 2
    end
  end

  describe "literal `__block__` wrapper end-to-end (bw mutagen-wrd.15)" do
    # The enumerator's `node_line/1` only reads metadata from 3-tuples
    # (`{form, meta, args}`). A bare literal (`0`, `true`, …) carries no
    # metadata of its own, so the line check at
    # `mutation_enumerator.ex:224` filters it out as "uncovered" even if
    # its parent operator IS covered. The parser wraps a literal as
    # `{:__block__, meta, [value]}` in shapes where it carries token /
    # line / column info; in that case `node_line/1` returns the
    # wrapper's line and the site survives the filter.
    #
    # This test injects a hand-built `__block__`-wrapped literal into a
    # synthetic AST and asserts the literal mutator produces a site
    # attributed to the wrapper's line. It is the end-to-end demonstration
    # the ticket calls for: the `__block__` shape lands on the right line
    # in the enumerator's site list.

    alias MutagenEx.Mutators

    defp inject_block_literal_ast(file_atom, module_atom, literal_line, literal_value) do
      # Build the same shape `Code.string_to_quoted/2` would produce for a
      # module containing a single function that returns a `__block__`-
      # wrapped literal. The line metadata on the wrapper is what the
      # enumerator reads.
      wrapped_literal =
        {:__block__, [token: inspect(literal_value), line: literal_line, column: 5],
         [literal_value]}

      defmodule_meta = [line: 1, column: 1]
      def_meta = [line: literal_line - 1, column: 3]

      ast =
        {:defmodule, defmodule_meta,
         [
           {:__aliases__, [line: 1, column: 11], [module_atom]},
           [
             do:
               {:def, def_meta,
                [
                  {:f, [line: literal_line - 1, column: 7], nil},
                  [do: wrapped_literal]
                ]}
           ]
         ]}

      %{file_atom => ast}
    end

    test "boolean __block__ wrapper produces a literal site at the wrapper's line" do
      file = "lib/blockbool.ex"
      cache = inject_block_literal_ast(file, :BlockBool, 5, true)
      scopes = [scope(file, BlockBool)]
      covered = covered_lines(file, [4, 5])

      result = MutationEnumerator.enumerate(cache, scopes, covered)

      literal_sites = Enum.filter(result.sites, &(&1.mutator == :literal))

      assert length(literal_sites) >= 1,
             "expected a literal site for the __block__-wrapped true; got sites=#{inspect(result.sites)} skipped=#{inspect(result.skipped)}"

      [literal_site | _] = literal_sites
      assert literal_site.line == 5, "site line should be the wrapper's line"
      assert literal_site.file == file
      assert literal_site.mutator == :literal

      # Site ID is content-addressed over the normalized AST. Normalization
      # strips :line/:column/:end_line/:end_column but PRESERVES :token
      # because that key is part of the AST's content (it tells
      # `Macro.to_string/1` which token to render); see
      # `mutagen.decision.content_addressed_ids`.
      injected_value = literal_site.original_ast
      expected_hash = Mutators.ast_hash(injected_value)
      assert literal_site.id == "#{file}:#{expected_hash}:literal"

      # Mutated AST preserves the wrapper and the positional meta so the
      # runner can restore the original byte-for-byte; `:token` is
      # intentionally dropped (the source token reflects the old value).
      assert {:__block__, meta, [false]} = literal_site.mutated_ast
      assert Keyword.get(meta, :line) == 5
      refute Keyword.has_key?(meta, :token)
    end

    test "integer 0 __block__ wrapper produces a literal site at the wrapper's line" do
      file = "lib/blockint.ex"
      cache = inject_block_literal_ast(file, :BlockInt, 7, 0)
      scopes = [scope(file, BlockInt)]
      covered = covered_lines(file, [6, 7])

      result = MutationEnumerator.enumerate(cache, scopes, covered)

      literal_sites = Enum.filter(result.sites, &(&1.mutator == :literal))

      assert length(literal_sites) >= 1,
             "expected a literal site for the __block__-wrapped 0; got sites=#{inspect(result.sites)} skipped=#{inspect(result.skipped)}"

      [literal_site | _] = literal_sites
      assert literal_site.line == 7
      assert literal_site.file == file

      assert {:__block__, _meta, [1]} = literal_site.mutated_ast
    end

    test "uncovered __block__-wrapped literal is filtered (r2 ordering still holds)" do
      file = "lib/blockfilt.ex"
      cache = inject_block_literal_ast(file, :BlockFilt, 9, 1)
      scopes = [scope(file, BlockFilt)]
      # Cover only line 8 (the def line); leave the literal's line 9
      # uncovered.
      covered = covered_lines(file, [8])

      result = MutationEnumerator.enumerate(cache, scopes, covered)

      literal_sites = Enum.filter(result.sites, &(&1.mutator == :literal))
      literal_skips = Enum.filter(result.skipped, &(&1.mutator == :literal))

      assert literal_sites == [],
             "uncovered literal should produce no site; got: #{inspect(literal_sites)}"

      assert literal_skips == [],
             "uncovered literal should be filtered before validate, not skipped; got: #{inspect(literal_skips)}"
    end
  end

  describe "bare-literal parent-line inheritance (bw mutagen-wrd.16)" do
    # Elixir 1.19's `Code.string_to_quoted(..., token_metadata: true)` does
    # NOT wrap atomic literals in `{:__block__, meta, [value]}` when they
    # appear as bare children of operator / clause-head tuples — only the
    # parent operator/clause-head 3-tuple carries `:line`. The old
    # enumerator's `is_nil(line) -> acc` filter dropped every such site.
    # bw mutagen-wrd.16 added parent-line inheritance: a bare literal's
    # effective line is the nearest enclosing 3-tuple's `:line` (the
    # "ambient line" threaded by the walker). These tests pin that
    # behaviour against real `Code.string_to_quoted/2` output so a future
    # regression to a metadata-only walker would be caught here, before
    # the e2e fixture.
    test "bare 0 in a covered comparison produces a literal site on the comparison's line" do
      # `n > 0` parses to `{:>, [line: 2, ...], [{:n, [...], nil}, 0]}` —
      # the `0` is a bare child of the comparison and has no metadata.
      source = """
      defmodule Comp do
        def positive?(n), do: n > 0
      end
      """

      cache = ast_cache("lib/comp.ex", source)
      scopes = [scope("lib/comp.ex", Comp)]
      covered = covered_lines("lib/comp.ex", [1, 2, 3])

      result = MutationEnumerator.enumerate(cache, scopes, covered)

      literal_sites = Enum.filter(result.sites, &(&1.mutator == :literal))

      assert length(literal_sites) == 1,
             "expected exactly one literal site for bare `0`; got sites=#{inspect(result.sites)}"

      [site] = literal_sites
      # The bare `0`'s effective line is its parent `>`'s line (2).
      assert site.line == 2, "literal site should inherit the parent comparison's line"
      assert site.original_ast == 0
      assert site.mutated_ast == 1
    end

    test "bare 1 in a covered `do: 1` keyword-shorthand body produces a literal site" do
      # `do: 1` puts a bare `1` as the value of a keyword tuple inside
      # the `def`'s args list. The walker must thread the parent's line
      # through the keyword's two-tuple shape.
      source = """
      defmodule Body do
        def one, do: 1
      end
      """

      cache = ast_cache("lib/body.ex", source)
      scopes = [scope("lib/body.ex", Body)]
      covered = covered_lines("lib/body.ex", [1, 2, 3])

      result = MutationEnumerator.enumerate(cache, scopes, covered)

      literal_sites = Enum.filter(result.sites, &(&1.mutator == :literal))

      assert length(literal_sites) == 1,
             "expected exactly one literal site for bare `1`; got sites=#{inspect(result.sites)}"

      [site] = literal_sites
      assert site.line == 2
      assert site.original_ast == 1
      assert site.mutated_ast == 0
    end

    test "bare literal whose ambient line is UNCOVERED produces no site (r2 still wins)" do
      # The literal's only available line is its parent's line. If the
      # parent's line isn't in `covered_lines`, the inherited line must
      # still fail the coverage check — inheritance does NOT bypass r2.
      source = """
      defmodule Uncov do
        def positive?(n), do: n > 0
        def negative?(n), do: n < 0
      end
      """

      cache = ast_cache("lib/uncov.ex", source)
      scopes = [scope("lib/uncov.ex", Uncov)]
      # Cover only line 2 (positive?); leave line 3 (negative?) uncovered.
      covered = covered_lines("lib/uncov.ex", [2])

      result = MutationEnumerator.enumerate(cache, scopes, covered)

      literal_sites = Enum.filter(result.sites, &(&1.mutator == :literal))

      assert length(literal_sites) == 1,
             "expected exactly one literal site (from line 2 only); got: #{inspect(literal_sites)}"

      [site] = literal_sites
      assert site.line == 2

      # And no literal SKIP entry — the uncovered literal was filtered
      # before validate, per r2.
      literal_skips = Enum.filter(result.skipped, &(&1.mutator == :literal))
      assert literal_skips == [],
             "uncovered literal must be filtered, not skipped: #{inspect(literal_skips)}"
    end

    test "bare 0 in a case clause head inherits the clause head's line" do
      # `0 -> :zero` parses to `{:->, [line: 3, ...], [[0], :zero]}` —
      # the `0` is a bare child of a list child of the clause-head
      # 3-tuple. The walker must thread `:->`s line through the list.
      source = """
      defmodule Cl do
        def classify(n) do
          case n do
            0 -> :zero
            1 -> :one
            _ -> :other
          end
        end
      end
      """

      cache = ast_cache("lib/cl.ex", source)
      scopes = [scope("lib/cl.ex", Cl)]
      covered = covered_lines("lib/cl.ex", Enum.to_list(1..10))

      result = MutationEnumerator.enumerate(cache, scopes, covered)

      literal_sites = Enum.filter(result.sites, &(&1.mutator == :literal))

      # Two bare literal candidates: `0` on line 4 and `1` on line 5.
      assert length(literal_sites) == 2

      lines = literal_sites |> Enum.map(& &1.line) |> Enum.sort()
      assert lines == [4, 5]
    end

    test "determinism: two consecutive runs with bare literals produce identical site lists" do
      # r1 still holds with the new walker. The hand-rolled recursion
      # must mirror `Macro.prewalk`'s left-to-right depth-first order.
      source = """
      defmodule Det do
        def f(n), do: n > 0
        def g(n), do: n < 1
        def h(n), do: n == -1
      end
      """

      cache = ast_cache("lib/det.ex", source)
      scopes = [scope("lib/det.ex", Det)]
      covered = covered_lines("lib/det.ex", Enum.to_list(1..6))

      r1 = MutationEnumerator.enumerate(cache, scopes, covered)
      r2 = MutationEnumerator.enumerate(cache, scopes, covered)

      assert r1 == r2

      literal_ids =
        r1.sites
        |> Enum.filter(&(&1.mutator == :literal))
        |> Enum.map(& &1.id)

      # All three bare literals (0, 1, -1) are sited deterministically.
      assert length(literal_ids) == 3
    end
  end
end
