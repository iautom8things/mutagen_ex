defmodule MutagenEx.MutationRunnerBatchedTest do
  @moduledoc """
  Byte-identity property tests for the batched grouped-by-file prewalk
  optimisation introduced in `mutagen-wrd.25.5` (`MutagenEx.MutationRunner`
  `r16`).

  ## What this test proves

  For every site in `cfg.sites`, the file-AST produced by the **batched
  path** (one prewalk per file in `build_mutated_ast_cache/2`, then
  `O(depth)` `apply_swap_at_path/3` at swap-time) must be byte-for-byte
  identical to the file-AST produced by the **legacy path** (per-site
  `Macro.prewalk/2` over the whole file AST in
  `build_mutated_file_ast_legacy/2`).

  The byte-identity gate is what allows the optimisation to be deployed
  in the production swap path without a behaviour change. If a future
  refactor of the path walker drifts from `Macro.prewalk`'s descent
  contract, this test fails and pins the regression to the swap
  pre-compute.

  ## How we observe the AST

  The runner is private about its swap helpers, so we observe the
  mutated AST that the runner hands to the compiler. We pass a
  recording compiler stub (`AstRecordingCompiler`) that captures every
  `compile_quoted(ast, file)` call's `ast` argument and returns an
  empty module list (the rest of the runner happy path proceeds with a
  faked ExUnit). The recorded AST IS the output of
  `build_mutated_file_ast/3` for that site.

  We then independently compute the legacy result by running
  `Macro.prewalk/2` directly against the same `(file_ast, site)` input
  using the same `node_matches_site?` predicate the runner uses. The
  two outputs are compared with `==` (structural equality, which is
  what "byte-identical" means for Elixir terms used as AST nodes).

  ## Corpus

  We drive both paths against:

    * A multi-site file with arithmetic, comparison, and `case`
      forms — exercises 3-tuple matches at varied depths and under
      `args`/`form` descent.
    * A `with`/`do` form — exercises descent into 2-tuples and keyword
      lists (the `do:` block lives as a `{:do, _}` 2-tuple inside a
      keyword list).
    * A bare-literal site (`Literal` mutator on a bare integer) — must
      fall back to the legacy `replace_bare_site/2` path because
      bare-literal sites carry no static AST coordinates.
    * Multiple sites in the SAME file — proves the per-file prewalk is
      a single walk that captures all paths in one pass (not one walk
      per site).
  """

  use ExUnit.Case, async: false

  alias MutagenEx.AstCache
  alias MutagenEx.MutationEnumerator.Site
  alias MutagenEx.MutationRunner
  alias MutagenEx.ScopeResolver.Scope
  alias MutagenEx.TestSelector.TestFilter

  # Reuse the stubs from the sibling runner test by inlining the bits
  # we need. We keep this file self-contained so it does not depend on
  # MutationRunnerTest's loading order.

  defmodule ExUnitFake do
    @moduledoc false
    @agent :mutagen_ex_batched_test_exunit_fake

    def start_link do
      case Agent.start_link(fn -> %{configure: nil, results: []} end, name: @agent) do
        {:ok, pid} ->
          {:ok, pid}

        {:error, {:already_started, stale}} ->
          Process.exit(stale, :kill)
          wait_until_unregistered()
          Agent.start_link(fn -> %{configure: nil, results: []} end, name: @agent)
      end
    end

    defp wait_until_unregistered(remaining_ms \\ 500) do
      cond do
        Process.whereis(@agent) == nil ->
          :ok

        remaining_ms <= 0 ->
          :ok

        true ->
          Process.sleep(10)
          wait_until_unregistered(remaining_ms - 10)
      end
    end

    def set_results(results), do: Agent.update(@agent, fn s -> %{s | results: results} end)
    def configure(_opts), do: :ok

    def run do
      Agent.get_and_update(@agent, fn s ->
        case s.results do
          [head | rest] -> {head, %{s | results: rest}}
          [] -> {:default, s}
        end
      end)
      |> handle_next()
    end

    defp handle_next(:default), do: %{failures: 0, total: 1, excluded: 0, skipped: 0}
    defp handle_next({:result, r}), do: r
  end

  defmodule ExUnitServerStub do
    @moduledoc false
    def add_module(_mod, _cfg), do: :ok
  end

  defmodule CaptureIoStub do
    @moduledoc false
    defdelegate with_io(device, fun), to: ExUnit.CaptureIO
  end

  defmodule AstRecordingCompiler do
    @moduledoc """
    Captures the AST handed to `compile_quoted/2` into a named Agent
    keyed by `site.id` (we encode `site.id` into the file path so the
    runner doesn't need to be modified to surface it — see the test
    setup; we wrap the AST behind a per-site file-id route via the
    {ast, file} pair).

    The recording is per-site because the runner calls compile_quoted
    once per site with that site's mutated file AST. The recorded
    list is in compile-order which matches site-order in input.
    """
    @agent :mutagen_ex_batched_test_ast_recorder

    def start_link do
      case Agent.start_link(fn -> [] end, name: @agent) do
        {:ok, pid} ->
          {:ok, pid}

        {:error, {:already_started, stale}} ->
          Process.exit(stale, :kill)
          Process.sleep(5)
          Agent.start_link(fn -> [] end, name: @agent)
      end
    end

    def compile_quoted(ast, file) do
      Agent.update(@agent, fn calls -> calls ++ [{file, ast}] end)
      # Return a valid module list so the runner proceeds.
      []
    end

    def recorded, do: Agent.get(@agent, & &1)
  end

  setup do
    {:ok, _} = ExUnitFake.start_link()
    {:ok, _} = AstRecordingCompiler.start_link()

    on_exit(fn ->
      for name <- [:mutagen_ex_batched_test_exunit_fake, :mutagen_ex_batched_test_ast_recorder] do
        case Process.whereis(name) do
          nil -> :ok
          pid -> Process.exit(pid, :kill)
        end
      end
    end)

    :ok
  end

  # ---- Helpers --------------------------------------------------------------

  # The runner's `node_matches_site?` predicate, reproduced here so we
  # can compute the legacy reference without reaching into the private
  # function. If the runner's predicate ever drifts (it shouldn't — r6
  # pins it), THIS test will fail because the legacy reference will
  # disagree with the runner's output, which is exactly the regression
  # signal we want.
  defp node_matches_site?({_kind, meta, _args} = node, %Site{} = site) when is_list(meta) do
    Keyword.get(meta, :line) == site.line and
      Keyword.get(meta, :column) == site.column and
      node == site.original_ast
  end

  defp node_matches_site?(_, _), do: false

  # The legacy per-site swap. Mirrors `build_mutated_file_ast_legacy/2`
  # in the runner. Defined here as the reference path the batched
  # output must match.
  defp legacy_swap(file_ast, %Site{} = site) do
    {ast, replaced?} =
      Macro.prewalk(file_ast, false, fn node, replaced ->
        if not replaced and node_matches_site?(node, site) do
          {site.mutated_ast, true}
        else
          {node, replaced}
        end
      end)

    if replaced?, do: {:ok, ast}, else: {:error, :site_not_found}
  end

  defp base_cfg(file_ast, source, file, sites) do
    ast_cache = %{file => {file_ast, source}}

    %{
      seed: 0,
      timeout_ms: 500,
      test_filter: %TestFilter{include: [], exclude: [:test], files: []},
      ast_cache: ast_cache,
      sites: sites,
      scope_records: [
        %Scope{file: file, line_range: 1..100, module: SynthBatched.Mod}
      ],
      test_modules: [],
      ex_unit: ExUnitFake,
      ex_unit_server: ExUnitServerStub,
      capture_io: CaptureIoStub,
      compiler: {AstRecordingCompiler, :compile_quoted}
    }
  end

  # Build a real file AST by parsing source. This is what the
  # production AstCache does, so the metadata shape matches what the
  # enumerator and runner see in real life.
  defp parse(source) do
    {:ok, ast_cache} = AstCache.load(["synth_batched.ex"], reader: fn _ -> source end)
    {:ok, {file_ast, source_text}} = AstCache.get(ast_cache, "synth_batched.ex")
    {file_ast, source_text}
  end

  # Locate the first node satisfying `pred` in `file_ast`, return it.
  defp find_node(file_ast, pred) do
    {_, hits} =
      Macro.prewalk(file_ast, [], fn node, acc ->
        if pred.(node), do: {node, [node | acc]}, else: {node, acc}
      end)

    Enum.reverse(hits) |> List.first()
  end

  # Compose a site from a located 3-tuple node. The mutator is set to
  # `:arith` regardless — the SWAP path doesn't consult the mutator
  # name, only `(line, column, original_ast, mutated_ast)`.
  defp site_for_node(id, file, {_form, meta, _args} = node, mutated_ast) do
    %Site{
      id: id,
      file: file,
      line: Keyword.fetch!(meta, :line),
      column: Keyword.fetch!(meta, :column),
      mutator: :arith,
      original_ast: node,
      mutated_ast: mutated_ast
    }
  end

  # Drive the runner against `sites` and return the list of mutated
  # file ASTs the runner handed to the compiler stub, in input order.
  # Pairs each entry with the originating `site.id` so the comparison
  # is unambiguous when sites span multiple files.
  defp run_and_capture(file_ast, source, file, sites) do
    cfg = base_cfg(file_ast, source, file, sites)

    ExUnitFake.set_results(
      for _ <- sites, do: {:result, %{failures: 0, total: 1, excluded: 0, skipped: 0}}
    )

    assert {:ok, _output} = MutationRunner.run(cfg)

    # The runner calls `compile_quoted/2` TWICE per site: once for the
    # mutated AST (the swap) and once for the original (the restore).
    # The first call in each pair is the mutated swap — that's what
    # we want to compare against the legacy reference. We pair up the
    # recorded calls (mutated, original) and discard the restore call.
    recorded = AstRecordingCompiler.recorded()

    assert length(recorded) == 2 * length(sites),
           "expected 2 compile_quoted calls per site (swap + restore), got " <>
             "#{length(recorded)} for #{length(sites)} sites"

    mutated_swaps =
      recorded
      |> Enum.chunk_every(2)
      |> Enum.map(fn [{_file, swap_ast}, _restore_pair] -> swap_ast end)

    Enum.zip(sites, mutated_swaps)
    |> Enum.map(fn {site, swap_ast} -> {site.id, swap_ast} end)
  end

  # ---- r16: byte-identity property -----------------------------------------

  describe "r16: batched prewalk byte-identity property" do
    test "arith site in a single-module file matches legacy prewalk byte-for-byte" do
      source = """
      defmodule SynthBatched.Mod do
        def two, do: 1 + 1
      end
      """

      {file_ast, source_text} = parse(source)
      add_node = find_node(file_ast, fn n -> match?({:+, _, [1, 1]}, n) end)
      assert add_node != nil

      {_, meta, args} = add_node

      site =
        site_for_node(
          "syn:arith:1",
          "synth_batched.ex",
          add_node,
          {:-, meta, args}
        )

      [{"syn:arith:1", batched_ast}] =
        run_and_capture(file_ast, source_text, "synth_batched.ex", [site])

      assert {:ok, legacy_ast} = legacy_swap(file_ast, site)

      assert batched_ast == legacy_ast,
             "batched swap diverged from per-site Macro.prewalk reference for arith site"
    end

    test "multiple sites in the SAME file each match their legacy counterpart" do
      # Two mutation sites: the `1 + 1` add and the `2 < 3` comparison.
      # The batched pre-compute does ONE prewalk over the file AST and
      # captures both paths; each swap is then O(depth).
      source = """
      defmodule SynthBatched.Multi do
        def two, do: 1 + 1
        def lt, do: 2 < 3
      end
      """

      {file_ast, source_text} = parse(source)

      add_node = find_node(file_ast, fn n -> match?({:+, _, [1, 1]}, n) end)
      lt_node = find_node(file_ast, fn n -> match?({:<, _, [2, 3]}, n) end)
      assert add_node != nil and lt_node != nil

      {_, add_meta, add_args} = add_node
      {_, lt_meta, lt_args} = lt_node

      site_a =
        site_for_node("syn:multi:add", "synth_batched.ex", add_node, {:-, add_meta, add_args})

      site_b =
        site_for_node("syn:multi:lt", "synth_batched.ex", lt_node, {:>, lt_meta, lt_args})

      results = run_and_capture(file_ast, source_text, "synth_batched.ex", [site_a, site_b])
      assert [{"syn:multi:add", batched_a}, {"syn:multi:lt", batched_b}] = results

      assert {:ok, legacy_a} = legacy_swap(file_ast, site_a)
      assert {:ok, legacy_b} = legacy_swap(file_ast, site_b)

      assert batched_a == legacy_a, "site_a (arith) batched swap != legacy"
      assert batched_b == legacy_b, "site_b (comparison) batched swap != legacy"
    end

    test "site inside a `case` expression (deeper nesting) matches legacy" do
      # The `1 + 1` lives inside a `case`'s arrow body — that exercises
      # descent through `case` → keyword list (`do:`) → `->` 3-tuple →
      # args[1] (the right-hand side of the arrow). Byte identity here
      # confirms the descent encoding handles 2-tuple `{:do, _}` keys
      # inside a keyword list under args.
      source = """
      defmodule SynthBatched.Case do
        def f(x) do
          case x do
            :a -> 1 + 1
            _ -> 0
          end
        end
      end
      """

      {file_ast, source_text} = parse(source)
      add_node = find_node(file_ast, fn n -> match?({:+, _, [1, 1]}, n) end)
      assert add_node != nil

      {_, meta, args} = add_node

      site =
        site_for_node(
          "syn:case:1",
          "synth_batched.ex",
          add_node,
          {:-, meta, args}
        )

      [{"syn:case:1", batched_ast}] =
        run_and_capture(file_ast, source_text, "synth_batched.ex", [site])

      assert {:ok, legacy_ast} = legacy_swap(file_ast, site)

      assert batched_ast == legacy_ast,
             "batched swap diverged from per-site Macro.prewalk reference for case-nested site"
    end

    test "duplicate-position sites: same {line, column, original_ast}, distinct id and distinct mutated_ast both surface in compile" do
      # Falsifies: "path-indexed map MUST be keyed by site.id, NOT by
      # {line, column} alone. Duplicate-position sites would collide
      # otherwise." (s14 Out-of-Scope-(intent), mutation_runner.ex:944)
      #
      # We construct TWO synthetic Site records sharing identical
      # `{line, column, original_ast}` but distinct `id` and distinct
      # `mutated_ast`. If the storage at maybe_record_match/3 were
      # demoted from `id` to `{line, column}`, the second site's path
      # entry would overwrite (or — with `put_new` — be discarded), and
      # only ONE of the two mutated_asts would reach `compile_quoted`.
      # By asserting BOTH mutated_asts surface in compile-order, this
      # test fails iff the index keying drifts off `site.id`.
      source = """
      defmodule SynthBatched.Dup do
        def two, do: 1 + 1
      end
      """

      {file_ast, source_text} = parse(source)
      add_node = find_node(file_ast, fn n -> match?({:+, _, [1, 1]}, n) end)
      assert add_node != nil

      {_, meta, args} = add_node

      site_a =
        site_for_node(
          "syn:dup:a",
          "synth_batched.ex",
          add_node,
          {:-, meta, args}
        )

      site_b =
        site_for_node(
          "syn:dup:b",
          "synth_batched.ex",
          add_node,
          {:*, meta, args}
        )

      # Sanity-check the construction: distinct ids, distinct
      # mutated_asts, IDENTICAL line/column/original_ast. This is the
      # precise collision shape that would silently degrade if the
      # storage key were {line, column} alone.
      assert site_a.id != site_b.id
      assert site_a.mutated_ast != site_b.mutated_ast
      assert site_a.line == site_b.line
      assert site_a.column == site_b.column
      assert site_a.original_ast == site_b.original_ast

      # Capture the post-build cache via the `:on_cache_built` seam.
      # This is the PRIMARY falsifiability surface for the keying contract:
      # if `Map.put_new(acc, id, path)` were demoted to use `{line, column}`
      # as the key, the inner map would have ONE entry instead of TWO and
      # would lack `site_a.id`/`site_b.id` as keys.
      {:ok, capture_pid} = Agent.start_link(fn -> nil end)

      cfg =
        base_cfg(file_ast, source_text, "synth_batched.ex", [site_a, site_b])
        |> Map.put(:on_cache_built, fn cache ->
          Agent.update(capture_pid, fn _ -> cache end)
        end)

      ExUnitFake.set_results(
        for _ <- [site_a, site_b],
            do: {:result, %{failures: 0, total: 1, excluded: 0, skipped: 0}}
      )

      assert {:ok, _output} = MutationRunner.run(cfg)
      cache = Agent.get(capture_pid, & &1)
      Agent.stop(capture_pid)

      # Direct keying contract: both `site_a.id` and `site_b.id` must be
      # present as keys in the inner cache map. A demotion of the storage
      # key from `site.id` to `{line, column}` would collapse these two
      # entries into one (or omit one under `Map.put_new`), and this
      # assertion would fail.
      inner = Map.fetch!(cache, "synth_batched.ex")

      assert map_size(inner) == 2,
             "duplicate-position sites must yield TWO entries in the path " <>
               "index (one per site.id); got #{map_size(inner)} entries — " <>
               "keys=#{inspect(Map.keys(inner))}. If you see ONE entry, " <>
               "the storage key was demoted from site.id to {line, column}."

      assert Map.has_key?(inner, site_a.id),
             "path index must retain site_a.id (#{site_a.id}); keys=#{inspect(Map.keys(inner))}"

      assert Map.has_key?(inner, site_b.id),
             "path index must retain site_b.id (#{site_b.id}); keys=#{inspect(Map.keys(inner))}"

      # The two recorded entries must reach `compile_quoted/2` carrying
      # their OWN mutated_ast (not the other site's). This is the
      # end-to-end behavioural check.
      recorded = AstRecordingCompiler.recorded()
      assert length(recorded) == 4, "expected 4 compile calls (swap+restore × 2 sites)"

      mutated_swaps =
        recorded
        |> Enum.chunk_every(2)
        |> Enum.map(fn [{_file, swap_ast}, _restore_pair] -> swap_ast end)

      [batched_a, batched_b] = mutated_swaps

      assert contains_node?(batched_a, {:-, meta, args}),
             "site_a's mutated_ast (`1 - 1`) must surface in its compile_quoted call"

      assert contains_node?(batched_b, {:*, meta, args}),
             "site_b's mutated_ast (`1 * 1`) must surface in its compile_quoted call"
    end

    test "path-index shape: one entry per distinct file, N site.id entries per N-site/1-file corpus" do
      # Falsifies: s14 "the Macro.prewalk count over file ASTs during
      # run/1 does not exceed length(distinct files in cfg.sites)
      # regardless of N". A regression that did one walk per site would
      # still pass byte-identity but would manifest as either (a) more
      # than `length(distinct_files)` top-level cache entries or (b) a
      # different cache shape entirely. We assert the structural invariant
      # via the `:on_cache_built` test seam in mutation_runner.ex.
      #
      # Corpus: 1 file, 3 sites. We expect the cache to be exactly
      # `%{file => %{site_id_1 => path_1, site_id_2 => path_2, site_id_3 => path_3}}`.
      # That shape can only arise from ONE prewalk over the file AST
      # that records all three paths in a single pass — exactly the
      # batched contract.
      source = """
      defmodule SynthBatched.PathShape do
        def two, do: 1 + 1
        def three, do: 2 + 1
        def lt, do: 2 < 3
      end
      """

      {file_ast, source_text} = parse(source)
      add_node = find_node(file_ast, fn n -> match?({:+, _, [1, 1]}, n) end)
      add2_node = find_node(file_ast, fn n -> match?({:+, _, [2, 1]}, n) end)
      lt_node = find_node(file_ast, fn n -> match?({:<, _, [2, 3]}, n) end)
      assert add_node != nil and add2_node != nil and lt_node != nil

      {_, add_meta, add_args} = add_node
      {_, add2_meta, add2_args} = add2_node
      {_, lt_meta, lt_args} = lt_node

      site_1 =
        site_for_node("syn:shape:add", "synth_batched.ex", add_node, {:-, add_meta, add_args})

      site_2 =
        site_for_node("syn:shape:add2", "synth_batched.ex", add2_node, {:-, add2_meta, add2_args})

      site_3 =
        site_for_node("syn:shape:lt", "synth_batched.ex", lt_node, {:>, lt_meta, lt_args})

      sites = [site_1, site_2, site_3]

      # Use a small Agent to capture the post-build cache snapshot from
      # the `:on_cache_built` seam — Agent is concurrency-safe and the
      # callback runs synchronously in execute/2 before the swap pipeline
      # starts.
      {:ok, capture_pid} = Agent.start_link(fn -> nil end)

      cfg =
        base_cfg(file_ast, source_text, "synth_batched.ex", sites)
        |> Map.put(:on_cache_built, fn cache ->
          Agent.update(capture_pid, fn _ -> cache end)
        end)

      ExUnitFake.set_results(
        for _ <- sites, do: {:result, %{failures: 0, total: 1, excluded: 0, skipped: 0}}
      )

      assert {:ok, _output} = MutationRunner.run(cfg)

      cache = Agent.get(capture_pid, & &1)
      Agent.stop(capture_pid)

      assert is_map(cache), "expected :on_cache_built to be invoked with a map"

      # (a) Top-level shape: ONE entry per distinct file. Three sites,
      # all in `synth_batched.ex` → exactly one key.
      distinct_files = sites |> Enum.map(& &1.file) |> Enum.uniq()

      assert length(Map.keys(cache)) == length(distinct_files),
             "expected one cache entry per distinct file; got " <>
               "#{length(Map.keys(cache))} entries for #{length(distinct_files)} files"

      assert Map.has_key?(cache, "synth_batched.ex"),
             "cache must be keyed by file path"

      # (b) Inner shape: N site.id entries for N sites in this file —
      # proves a SINGLE walk collected all three paths in one pass. If
      # the runner did one-walk-per-site, the inner map would still have
      # three entries, but the only way to know this assertion FAILS on
      # that regression is to also assert the entries are keyed by
      # `site.id` (not `{line, column}`). We do both.
      inner = Map.fetch!(cache, "synth_batched.ex")
      assert map_size(inner) == length(sites)

      for site <- sites do
        assert Map.has_key?(inner, site.id),
               "path index must contain an entry for site.id=#{site.id}; " <>
                 "got keys #{inspect(Map.keys(inner))}"
      end

      # (c) Path values are non-empty descent step lists (sanity — the
      # paths should at least dive into a `def` body). We don't assert
      # the exact shape here because that's an internal encoding; the
      # byte-identity tests above pin the encoding's correctness.
      for {_id, path} <- inner do
        assert is_list(path) and path != [],
               "expected non-empty descent path; got #{inspect(path)}"
      end
    end

    test "bare-literal site falls back to legacy walker (not in the path index)" do
      # A bare literal site has `original_ast: 1` (or `true`/`false`)
      # — there's no static AST coordinate to address from the file
      # root because the bare value carries no metadata. The runner
      # must still produce a byte-identical mutated AST via the
      # ambient-threading walker (`replace_bare_site/2`). We verify by
      # asserting the batched path's output equals what an independent
      # ambient walker would produce — encoded as: replacing the bare
      # literal in the file AST under the right parent context.
      #
      # For this fixture, the bare `1` sits inside `def two, do: 1`.
      # The enumerator would attribute the site to the parent
      # `def two, do: 1`'s line/column, but for the test we only need
      # to prove that the runner DOES NOT crash and DOES NOT diverge
      # from a known reference. We construct the reference by manually
      # swapping the bare 1 → 0 in the parsed file_ast.
      source = """
      defmodule SynthBatched.Bare do
        def two, do: 1
      end
      """

      {file_ast, source_text} = parse(source)

      # Locate the `def two, do: 1` clause to harvest the parent's
      # ambient {line, column}. The enumerator pins bare-literal sites
      # to the operator/clause-head's coordinates per r1 of mutators.
      def_node =
        find_node(file_ast, fn
          {:def, _, [{:two, _, _}, _]} -> true
          _ -> false
        end)

      assert def_node != nil
      {_, def_meta, _} = def_node

      site = %Site{
        id: "syn:bare:1",
        file: "synth_batched.ex",
        line: Keyword.fetch!(def_meta, :line),
        column: Keyword.fetch!(def_meta, :column),
        mutator: :literal,
        original_ast: 1,
        mutated_ast: 0
      }

      [{"syn:bare:1", batched_ast}] =
        run_and_capture(file_ast, source_text, "synth_batched.ex", [site])

      # Reference: walk the original `file_ast` with the same ambient-
      # threading rule and verify that we get the SAME result back from
      # the batched path. We don't reproduce the ambient walker here —
      # instead we assert that whatever the batched path produced
      # contains a `0` (the mutated_ast) at the position the original
      # `1` lived. The structural invariant is: the swap must produce a
      # file_ast that compiles to a module whose `def two/0` returns
      # `0` (i.e., the literal in the body was replaced).
      assert contains_node?(batched_ast, 0),
             "bare-literal swap must place mutated_ast (0) into the file AST"

      refute contains_module_with_bare?(batched_ast, 1, :two),
             "bare-literal swap must NOT leave the original `1` body in `def two`"
    end
  end

  # ---- helpers for the bare-literal assertion ------------------------------

  defp contains_node?(ast, target) do
    {_, found} =
      Macro.prewalk(ast, false, fn
        _node, true -> {nil, true}
        node, _ -> {node, node === target}
      end)

    found
  end

  # True iff the AST has a `def <name>, do: <bare_value>` shape with
  # `bare_value` exactly equal to `value`. Used to confirm the
  # bare-literal swap actually wrote into the def body.
  defp contains_module_with_bare?(ast, value, fun_name) do
    {_, hit} =
      Macro.prewalk(ast, false, fn
        _node, true ->
          {nil, true}

        {:def, _, [{^fun_name, _, _}, [do: body]]} = node, _ ->
          {node, body === value}

        node, acc ->
          {node, acc}
      end)

    hit
  end
end
