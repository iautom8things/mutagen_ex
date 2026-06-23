defmodule MutagenEx.ScopeResolverTest do
  @moduledoc """
  Tests for `MutagenEx.ScopeResolver.resolve/2`.

  Coverage of the scenarios in `.spec/specs/scope_resolution.spec.md`:

    * `mutagen.scope_resolution.s1` — file target resolves to one record per
      `defmodule`, with `line_range` covering the full block.
    * `mutagen.scope_resolution.s2` — `Module.Name` resolves to a single
      record naming the file containing the matching `defmodule`.
    * `mutagen.scope_resolution.s3` — MFA target with arity selects only the
      matching clause; other clauses with different arities are excluded.
    * `mutagen.scope_resolution.s4` — arity-less function-shaped target
      returns `:arity_required`.
    * `mutagen.scope_resolution.s5` — colon-form target returns
      `:colon_syntax_unsupported`.
    * `mutagen.scope_resolution.s6` — multi-`defmodule` file, module target
      returns only the targeted module's range.
    * `mutagen.scope_resolution.s7` — resolver does not modify any file on
      disk.

  Plus error-path coverage for unknown modules / functions and the
  injectable-loader seam from `r7`.

  Covers spec-verification stubs `mutagen.scope_resolution.v1` and `.v2`.
  """

  use ExUnit.Case, async: true

  alias MutagenEx.ScopeResolver
  alias MutagenEx.ScopeResolver.Scope

  # Synthetic source helpers — per L-Tt1 / r7, every test feeds bytes via the
  # injectable loader. No on-disk fixtures.

  defp one_module_source do
    # 30 lines, single defmodule. The body is padded with comments so the
    # `line_range` for the file target genuinely covers 1..30 per s1.
    body =
      Enum.map(2..29, fn _ -> "  # filler" end)
      |> Enum.join("\n")

    """
    defmodule Foo do
    #{body}
    end
    """
  end

  defp multi_module_source do
    # Two defmodules in one file. A spans 1..10, B spans 12..25.
    a_filler = Enum.map(3..9, fn _ -> "  # in A" end) |> Enum.join("\n")
    b_filler = Enum.map(14..24, fn _ -> "  # in B" end) |> Enum.join("\n")

    a_block = "defmodule A do\n  def hello, do: :a\n#{a_filler}\nend"
    sep = ""
    b_block = "defmodule B do\n  def world(x), do: x\n#{b_filler}\nend"

    a_block <> "\n" <> sep <> "\n" <> b_block <> "\n"
  end

  defp mfa_source do
    """
    defmodule Foo do
      def bar(x), do: x

      def bar(x, y) do
        x + y
      end

      def baz(x) when x > 0 do
        x
      end

      defp helper(_), do: :ok
    end
    """
  end

  defp nested_module_source do
    """
    defmodule Foo.Bar do
      def baz(x), do: x
    end
    """
  end

  defp loader_for(map) do
    fn path ->
      case Map.fetch(map, path) do
        {:ok, source} -> source
        :error -> raise File.Error, action: "read file", reason: :enoent, path: path
      end
    end
  end

  describe "file targets (r1, s1)" do
    test "single-defmodule file returns one record covering the full block" do
      source = one_module_source()
      loader = loader_for(%{"lib/foo.ex" => source})

      assert {:ok, [%Scope{file: "lib/foo.ex", line_range: 1..30//1, module: Foo}]} =
               ScopeResolver.resolve("lib/foo.ex", loader: loader)
    end

    test "multi-defmodule file returns one record per defmodule (r1)" do
      source = multi_module_source()
      loader = loader_for(%{"lib/multi.ex" => source})

      assert {:ok, scopes} = ScopeResolver.resolve("lib/multi.ex", loader: loader)
      assert length(scopes) == 2

      [a_scope, b_scope] = scopes
      assert a_scope.module == A
      assert a_scope.file == "lib/multi.ex"
      assert a_scope.line_range.first == 1
      assert a_scope.line_range.last == 10

      assert b_scope.module == B
      assert b_scope.file == "lib/multi.ex"
      assert b_scope.line_range.first == 12
      assert b_scope.line_range.last == 25
    end

    test "file with no defmodule returns an empty list" do
      loader = loader_for(%{"lib/empty.ex" => "# nothing here\n"})

      assert {:ok, []} = ScopeResolver.resolve("lib/empty.ex", loader: loader)
    end
  end

  describe "module targets (r2, s2)" do
    test "Module.Name resolves to a single record in the file containing the defmodule" do
      source = nested_module_source()
      loader = loader_for(%{"lib/foo/bar.ex" => source})

      assert {:ok, [%Scope{file: "lib/foo/bar.ex", module: Foo.Bar} = scope]} =
               ScopeResolver.resolve("Foo.Bar",
                 loader: loader,
                 source_files: ["lib/foo/bar.ex"]
               )

      assert scope.line_range.first == 1
      assert scope.line_range.last == 3
    end

    test "stops at the first matching file (s2 explicit clause)" do
      sources = %{
        "lib/foo/bar.ex" => nested_module_source(),
        "lib/other.ex" => "defmodule Other do\nend\n"
      }

      # Wrap the loader so we can count calls. The resolver should only read
      # the file it actually finds the module in (plus, possibly, the ones
      # it had to scan first to discover the match).
      counter = :counters.new(1, [])

      loader = fn path ->
        :counters.add(counter, 1, 1)
        sources[path] || raise File.Error, action: "read file", reason: :enoent, path: path
      end

      assert {:ok, [%Scope{file: "lib/foo/bar.ex", module: Foo.Bar}]} =
               ScopeResolver.resolve("Foo.Bar",
                 loader: loader,
                 source_files: ["lib/foo/bar.ex", "lib/other.ex"]
               )

      # Stops after the first hit — `lib/other.ex` was not read.
      assert :counters.get(counter, 1) == 1
    end

    @tag :error_cases
    test "unknown module returns :module_not_found" do
      loader = loader_for(%{"lib/foo.ex" => "defmodule Foo do\nend\n"})

      assert {:error, :module_not_found, details} =
               ScopeResolver.resolve("Nope.Missing",
                 loader: loader,
                 source_files: ["lib/foo.ex"]
               )

      assert details.target == "Nope.Missing"
      # Atom safety (`mutagen.scope_resolution.r8`, mutagen-wrd.20): we
      # report the user's canonical module string, NEVER an atom built
      # from their input. `details.module` is the `"Elixir.Nope.Missing"`
      # canonical form so callers can render the error without
      # round-tripping through `String.to_atom/1`.
      assert details.module == "Elixir.Nope.Missing"
      assert is_binary(details.message)
    end
  end

  describe "MFA targets (r3, s3)" do
    test "Module.Name.function/arity selects only the matching arity's clauses" do
      loader = loader_for(%{"lib/foo.ex" => mfa_source()})

      assert {:ok, [%Scope{} = bar1]} =
               ScopeResolver.resolve("Foo.bar/1",
                 loader: loader,
                 source_files: ["lib/foo.ex"]
               )

      assert bar1.module == Foo
      assert bar1.file == "lib/foo.ex"
      # `def bar(x), do: x` is on line 2 only.
      assert bar1.line_range.first == 2
      assert bar1.line_range.last == 2

      assert {:ok, [%Scope{} = bar2]} =
               ScopeResolver.resolve("Foo.bar/2",
                 loader: loader,
                 source_files: ["lib/foo.ex"]
               )

      # `def bar(x, y) do x + y end` spans lines 4..6.
      assert bar2.line_range.first == 4
      assert bar2.line_range.last == 6
    end

    test "guarded MFA clauses resolve (head wrapped in :when)" do
      loader = loader_for(%{"lib/foo.ex" => mfa_source()})

      assert {:ok, [%Scope{} = baz]} =
               ScopeResolver.resolve("Foo.baz/1",
                 loader: loader,
                 source_files: ["lib/foo.ex"]
               )

      assert baz.line_range.first == 8
      assert baz.line_range.last == 10
    end

    test "defp clauses are reachable from MFA resolution" do
      loader = loader_for(%{"lib/foo.ex" => mfa_source()})

      assert {:ok, [%Scope{} = helper]} =
               ScopeResolver.resolve("Foo.helper/1",
                 loader: loader,
                 source_files: ["lib/foo.ex"]
               )

      assert helper.line_range.first == 12
      assert helper.line_range.last == 12
    end

    @tag :error_cases
    test "MFA with no matching arity returns :function_not_found" do
      loader = loader_for(%{"lib/foo.ex" => mfa_source()})

      assert {:error, :function_not_found, details} =
               ScopeResolver.resolve("Foo.bar/7",
                 loader: loader,
                 source_files: ["lib/foo.ex"]
               )

      assert details.target == "Foo.bar/7"
      # Module came from the AST (legitimate atom from parsing source).
      assert details.module == Foo
      # Function is reported as the user's string per atom safety
      # (`mutagen.scope_resolution.r8`, mutagen-wrd.20). We never
      # round-trip user input through `String.to_atom/1`.
      assert details.function == "bar"
      assert details.arity == 7
    end

    @tag :error_cases
    test "MFA inside a missing module returns :module_not_found" do
      loader = loader_for(%{"lib/foo.ex" => "defmodule Foo do\nend\n"})

      assert {:error, :module_not_found, _details} =
               ScopeResolver.resolve("Nope.bar/1",
                 loader: loader,
                 source_files: ["lib/foo.ex"]
               )
    end
  end

  describe "arity-required (r3, s4)" do
    @tag :error_cases
    test "Foo.bar (no /arity) returns :arity_required" do
      assert {:error, :arity_required, details} =
               ScopeResolver.resolve("Foo.bar")

      assert details.target == "Foo.bar"
      assert is_binary(details.message)
    end

    @tag :error_cases
    test "Foo.Bar.baz (no /arity) returns :arity_required" do
      assert {:error, :arity_required, %{target: "Foo.Bar.baz"}} =
               ScopeResolver.resolve("Foo.Bar.baz")
    end
  end

  describe "colon syntax rejection (r4, s5)" do
    @tag :error_cases
    test "lib/foo.ex:Foo.bar/1 returns :colon_syntax_unsupported" do
      assert {:error, :colon_syntax_unsupported, details} =
               ScopeResolver.resolve("lib/foo.ex:Foo.bar/1")

      assert details.target == "lib/foo.ex:Foo.bar/1"
      assert is_binary(details.message)
    end

    @tag :error_cases
    test "even file-shaped-with-colon is refused before file dispatch" do
      assert {:error, :colon_syntax_unsupported, _} =
               ScopeResolver.resolve("lib/a:b.ex")
    end
  end

  describe "multi-defmodule isolation (r5, s6)" do
    test "module target's line_range does not include sibling defmodules" do
      loader = loader_for(%{"lib/multi.ex" => multi_module_source()})

      assert {:ok, [%Scope{} = a]} =
               ScopeResolver.resolve("A",
                 loader: loader,
                 source_files: ["lib/multi.ex"]
               )

      # A spans 1..10, B starts at 12. The A range must not bleed into B.
      assert a.line_range.first == 1
      assert a.line_range.last == 10
      refute Enum.any?(12..25, fn line -> line in a.line_range end)
    end

    test "MFA target's line_range stays within the targeted module's block" do
      loader = loader_for(%{"lib/multi.ex" => multi_module_source()})

      assert {:ok, [%Scope{} = b_world]} =
               ScopeResolver.resolve("B.world/1",
                 loader: loader,
                 source_files: ["lib/multi.ex"]
               )

      # B's body starts at line 13 (`def world(x), do: x` after `defmodule B do`).
      assert b_world.line_range.first >= 12
      assert b_world.line_range.last <= 25
    end
  end

  describe "no on-disk side effects (r6, s7)" do
    test "resolver does not touch any file given by the loader" do
      source = mfa_source()

      # The loader counts reads; if the resolver tried to write, it would
      # need a different function. We assert the contract by structure: the
      # loader's signature is read-only and the resolver only invokes it.
      read_paths = :ets.new(:read_paths, [:set, :public])
      :ets.insert(read_paths, {"reads", []})

      loader = fn path ->
        [{_, prev}] = :ets.lookup(read_paths, "reads")
        :ets.insert(read_paths, {"reads", [path | prev]})
        source
      end

      assert {:ok, _} =
               ScopeResolver.resolve("Foo.bar/1",
                 loader: loader,
                 source_files: ["lib/foo.ex"]
               )

      [{_, reads}] = :ets.lookup(read_paths, "reads")
      :ets.delete(read_paths)
      assert reads == ["lib/foo.ex"]
    end

    test "no Cover server is started or cover/ directory created by resolver" do
      loader = loader_for(%{"lib/foo.ex" => mfa_source()})

      # Assert the *resolver* does not start a cover server or create a
      # cover/ directory — snapshot before/after rather than asserting the
      # global :cover_server singleton is absent. This test is async; a
      # concurrent cover-using test (coverage_runner_test r1 registers a
      # sentinel :cover_server, r3 starts real cover) can legitimately have
      # the singleton registered while this runs. The invariant under test
      # is "the resolver leaves cover state unchanged", not "no cover server
      # exists anywhere in the suite". This also keeps the test green under
      # `mix test --cover`, where the harness owns :cover_server and a
      # cover/ directory exists for the whole run.
      cover_before = Process.whereis(:cover_server)
      cover_dir_before = File.exists?("cover")

      assert {:ok, _} = ScopeResolver.resolve("Foo", loader: loader, source_files: ["lib/foo.ex"])

      assert Process.whereis(:cover_server) == cover_before
      assert File.exists?("cover") == cover_dir_before
    end
  end

  # ---------------------------------------------------------------------------
  # mutagen.scope_resolution.s8 — atom safety (r8, mutagen-wrd.20)
  # ---------------------------------------------------------------------------

  describe "atom safety (mutagen.scope_resolution.r8, s8)" do
    @describetag :atom_safety

    setup do
      # Warmup: parse the canonical fixture once so any AST-walk atoms it
      # *would* register (e.g. `:def`, `:bar`, `:"Elixir.Foo"`) are already
      # registered. After warmup, the only path that could move the counter
      # for the probes below is `String.to_atom/1` on user input — which we
      # are falsifying.
      loader = loader_for(%{"lib/foo.ex" => "defmodule Foo do\n  def bar(x), do: x\nend\n"})
      _ = ScopeResolver.resolve("Foo", loader: loader, source_files: ["lib/foo.ex"])
      _ = ScopeResolver.resolve("Foo.bar/1", loader: loader, source_files: ["lib/foo.ex"])
      :ok
    end

    # Helper: assert that a never-registered atom string did NOT get
    # registered as an atom by the BEAM during a call. Uses
    # `:erlang.binary_to_existing_atom/1` which raises `ArgumentError`
    # when the atom doesn't exist — a structural falsification that
    # doesn't suffer from the async-test atom_count noise that
    # measurements over `:erlang.system_info(:atom_count)` do.
    defp refute_atom_registered(name) when is_binary(name) do
      try do
        existing = :erlang.binary_to_existing_atom(name, :utf8)

        flunk(
          "atom #{inspect(existing)} was registered after the call (string: #{inspect(name)}); " <>
            "the resolver leaked user input through String.to_atom/1"
        )
      rescue
        ArgumentError -> :ok
      end
    end

    test "module target with never-registered name does not register the atom" do
      # Pre-fix: `string_to_module(target)` did `String.to_atom("Elixir." <> target)`
      # — after the call, `binary_to_existing_atom("Elixir." <> target)` would succeed.
      # Post-fix: `canonical_module_string/1` only builds a binary; no atom is
      # ever materialized from the user's input.
      loader = loader_for(%{"lib/foo.ex" => "defmodule Foo do\nend\n"})

      probe = "NeverRegisteredModule_#{System.unique_integer([:positive])}"
      expected_atom_string = "Elixir." <> probe

      # Sanity: the probe is genuinely unregistered before the call.
      assert_raise ArgumentError, fn ->
        :erlang.binary_to_existing_atom(expected_atom_string, :utf8)
      end

      assert {:error, :module_not_found, _details} =
               ScopeResolver.resolve(probe,
                 loader: loader,
                 source_files: ["lib/foo.ex"]
               )

      # The structural check: after the call, the canonical atom for the
      # user's input is STILL not registered.
      refute_atom_registered(expected_atom_string)
    end

    test "MFA target's module segment is not materialized as an atom" do
      loader = loader_for(%{"lib/foo.ex" => "defmodule Foo do\nend\n"})

      mod_seg = "NeverRegisteredForMFA_#{System.unique_integer([:positive])}"
      probe = mod_seg <> ".bar/1"
      expected_atom_string = "Elixir." <> mod_seg

      assert_raise ArgumentError, fn ->
        :erlang.binary_to_existing_atom(expected_atom_string, :utf8)
      end

      assert {:error, :module_not_found, _details} =
               ScopeResolver.resolve(probe,
                 loader: loader,
                 source_files: ["lib/foo.ex"]
               )

      refute_atom_registered(expected_atom_string)
    end

    test "MFA target's function-name segment is not materialized as an atom" do
      # The function-name segment is kept as a string and compared
      # against `Atom.to_string/1` of AST `def`-head atoms. If no
      # matching `def` exists in source, we return `:function_not_found`
      # — never growing the atom table from user input. (Function names
      # that DO appear in source are already AST atoms from parsing, so
      # `:function_not_found` only fires when the source has no
      # corresponding `def`.)
      loader = loader_for(%{"lib/foo.ex" => "defmodule Foo do\n  def bar(x), do: x\nend\n"})

      fn_seg = "never_registered_fn_#{System.unique_integer([:positive])}"
      probe = "Foo." <> fn_seg <> "/1"

      assert_raise ArgumentError, fn ->
        :erlang.binary_to_existing_atom(fn_seg, :utf8)
      end

      assert {:error, :function_not_found, details} =
               ScopeResolver.resolve(probe,
                 loader: loader,
                 source_files: ["lib/foo.ex"]
               )

      assert details.target == probe
      # `details.function` carries the user's string, not an atom.
      assert details.function == fn_seg
      assert is_binary(details.message)

      # Falsification: after the call, the function-name atom is still
      # NOT registered — even though the source has no matching `def`,
      # the resolver did not try to `String.to_atom/1` the user's segment
      # to "see" if a def matched.
      refute_atom_registered(fn_seg)
    end

    test "MFA target's function-name segment matches AST atoms by string (not atom)" do
      # The function-name string is compared against `Atom.to_string/1`
      # of each AST `def`-head atom. The source defines `:world` as a
      # `def` head — the AST atom is created by `Code.string_to_quoted/2`
      # during parsing of source on disk (a trusted, bounded corpus),
      # never from the user's `world` string.
      loader = loader_for(%{"lib/multi.ex" => multi_module_source()})

      # `world` IS in source as `def world(x), do: x` in module B.
      assert {:ok, [%Scope{module: B} = b_world]} =
               ScopeResolver.resolve("B.world/1",
                 loader: loader,
                 source_files: ["lib/multi.ex"]
               )

      assert b_world.line_range.first >= 12
      assert b_world.line_range.last <= 25
    end

    test "looping N distinct never-registered module targets registers zero of them" do
      # DOS shape (mutagen-wrd.20): a CI loop running
      # `mix mutagen --scope NeverRegisteredN`. Pre-fix, this grew the
      # atom table by exactly N (one fresh atom per call). Post-fix, the
      # falsification is structural: after the loop, NONE of the N
      # canonical atom strings are registered.
      loader = loader_for(%{"lib/foo.ex" => "defmodule Foo do\nend\n"})

      n = 50

      probes =
        for i <- 1..n do
          mod_str = "AtomSafeLoop_#{System.unique_integer([:positive])}_#{i}"
          {mod_str, "Elixir." <> mod_str}
        end

      for {probe, _expected_atom_string} <- probes do
        assert {:error, :module_not_found, _} =
                 ScopeResolver.resolve(probe,
                   loader: loader,
                   source_files: ["lib/foo.ex"]
                 )
      end

      # None of the N expected canonical atoms were registered. Pre-fix
      # this would fail on iteration 1.
      for {_probe, expected_atom_string} <- probes do
        refute_atom_registered(expected_atom_string)
      end
    end

    test "module_not_found details carry the canonical string form, not an atom" do
      # The error report exposes the module name to callers (JSON
      # reporter, etc.). For atom safety we expose the canonical
      # `"Elixir.X"` string; only when a real `defmodule` matched does an
      # atom appear (from the AST).
      loader = loader_for(%{"lib/foo.ex" => "defmodule Foo do\nend\n"})

      assert {:error, :module_not_found, details} =
               ScopeResolver.resolve("DoesNotExist.AnywhereSpecial",
                 loader: loader,
                 source_files: ["lib/foo.ex"]
               )

      assert details.module == "Elixir.DoesNotExist.AnywhereSpecial"
      assert is_binary(details.message)
    end

    test "successful resolution still returns an atom on %Scope{module: ...}" do
      # Atom safety isn't "never return any atom" — it's "never create one
      # from user input." Successful resolution finds an atom in the AST
      # (legitimate, created during source parsing) and exposes it on the
      # `%Scope{}` record.
      loader = loader_for(%{"lib/foo.ex" => mfa_source()})

      assert {:ok, [%Scope{module: mod}]} =
               ScopeResolver.resolve("Foo.bar/1",
                 loader: loader,
                 source_files: ["lib/foo.ex"]
               )

      assert is_atom(mod)
      assert Atom.to_string(mod) == "Elixir.Foo"
    end

    test "source no longer references String.to_atom (structural)" do
      # Provenance check (`mutagen.scope_resolution.r8`): the
      # implementation must not call `String.to_atom/1` on any path that
      # could see user input. Strip comment lines so commentary about the
      # forbidden call doesn't false-positive — only an actual call site
      # falsifies.
      non_comment_source =
        File.read!("lib/mutagen_ex/scope_resolver.ex")
        |> String.split("\n")
        |> Enum.reject(&String.match?(&1, ~r/^\s*#/))
        |> Enum.join("\n")

      refute non_comment_source =~ ~r/String\.to_atom\(/,
             "scope_resolver.ex must not call String.to_atom/1 — user input drives the inputs (mutagen.scope_resolution.r8)"
    end
  end

  describe "injectable loader seam (r7)" do
    test "default loader is &File.read!/1 (documented; not exercised on disk here)" do
      # We can't easily assert the default without writing a file. Instead,
      # we assert that omitting `:loader` yields a `:file_not_found` /
      # `:file_read_failed` error for a clearly-missing path, which proves
      # the default tried to read from disk.
      assert {:error, reason, _details} =
               ScopeResolver.resolve("/nonexistent/path/__definitely_not_there__.ex")

      assert reason in [:file_not_found, :file_read_failed]
    end

    test "loader is invoked exactly once per file for file-target resolution" do
      counter = :counters.new(1, [])

      loader = fn _path ->
        :counters.add(counter, 1, 1)
        "defmodule X do\nend\n"
      end

      assert {:ok, _} = ScopeResolver.resolve("lib/x.ex", loader: loader)
      assert :counters.get(counter, 1) == 1
    end
  end

  describe "wildcard determinism (mutagen.scope_resolution.r9, s9)" do
    # These tests exercise the F30 / CF7 sorted-wildcard contract for
    # `source_files/1`. They drive the no-`:source_files` branch via an
    # injectable `:wildcard_fn` that returns files in a known unsorted
    # order — the production code is expected to sort that output before
    # iteration so the resulting visit order is host-independent. Any
    # silent removal of `|> Enum.sort()` from `source_files/1` will fail
    # these tests on every host (the injected wildcard returns reverse-
    # lex order, which on any filesystem differs from the sorted form).

    @tag :wildcard_determinism
    test "source_files/1 sorts the wildcard result lexicographically (r9)" do
      unsorted = ["lib/zeta.ex", "lib/middle.ex", "lib/alpha.ex"]
      wildcard_fn = fn "lib/**/*.ex" -> unsorted end

      result = ScopeResolver.source_files(wildcard_fn: wildcard_fn)

      assert result == ["lib/alpha.ex", "lib/middle.ex", "lib/zeta.ex"]
      assert result == Enum.sort(unsorted)
      # Falsifiability guard: the unsorted input must actually differ
      # from its sorted form, otherwise removing `Enum.sort/1` from
      # production would pass this test by coincidence.
      refute unsorted == Enum.sort(unsorted)
    end

    @tag :wildcard_determinism
    test "source_files/1 sort is stable across two calls with the same wildcard (r9, s9)" do
      shuffled = ["lib/b/y.ex", "lib/a/z.ex", "lib/c/x.ex", "lib/a/m.ex"]
      wildcard_fn = fn "lib/**/*.ex" -> shuffled end

      first = ScopeResolver.source_files(wildcard_fn: wildcard_fn)
      second = ScopeResolver.source_files(wildcard_fn: wildcard_fn)

      assert first == second
      assert first == Enum.sort(shuffled)
    end

    @tag :wildcard_determinism
    test "explicit :source_files list bypasses sort entirely (r9 boundary)" do
      # Caller-supplied lists are not re-sorted — the caller already
      # chose an order. This pins the contract boundary so a future
      # "always sort" refactor doesn't silently swallow caller intent.
      caller_order = ["lib/zeta.ex", "lib/alpha.ex", "lib/middle.ex"]

      result = ScopeResolver.source_files(source_files: caller_order)

      assert result == caller_order
      refute result == Enum.sort(caller_order)
    end

    @tag :wildcard_determinism
    test "resolve/2 with no :source_files visits files in lex order via injected wildcard (r9 end-to-end)" do
      # End-to-end: the same `:wildcard_fn` opt that `source_files/1`
      # honours is plumbed via `resolve/2 -> resolve_module/4 ->
      # source_files/1`. The loader records the order it's invoked in;
      # with a reverse-lex wildcard, the recorded order must still be
      # lex-sorted (or production has dropped `|> Enum.sort()`).
      unsorted = ["lib/zeta.ex", "lib/middle.ex", "lib/alpha.ex"]
      wildcard_fn = fn "lib/**/*.ex" -> unsorted end

      test_pid = self()

      loader = fn path ->
        send(test_pid, {:loaded, path})
        # Return an empty module so the search proceeds through every
        # file in turn (no match -> :module_not_found at the end).
        "defmodule Nothing.Here do\nend\n"
      end

      assert {:error, :module_not_found, _details} =
               ScopeResolver.resolve("Some.Mod", loader: loader, wildcard_fn: wildcard_fn)

      visited =
        for path <- ["lib/alpha.ex", "lib/middle.ex", "lib/zeta.ex"] do
          assert_receive {:loaded, ^path}, 100
          path
        end

      assert visited == Enum.sort(unsorted)
    end
  end
end
