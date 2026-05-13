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

      # Same site SET, different ORDER: First's site comes first when
      # scoped First-then-Second.
      assert MapSet.new(r_first_then_second.sites) ==
               MapSet.new(r_second_then_first.sites)

      [first_a, first_b] = Enum.map(r_first_then_second.sites, & &1.mutator)
      [second_a, _second_b] = Enum.map(r_second_then_first.sites, & &1.mutator)

      assert first_a == :arith
      assert first_b == :arith
      assert second_a == :arith

      # The lines distinguish them: First's def f is line 2, Second's
      # def g is line 6.
      [line_a, line_b] = Enum.map(r_first_then_second.sites, & &1.line)
      assert line_a == 2
      assert line_b == 6

      [line_a2, line_b2] = Enum.map(r_second_then_first.sites, & &1.line)
      assert line_a2 == 6
      assert line_b2 == 2
    end
  end
end
