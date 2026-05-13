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
      assert details.module == Nope.Missing
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
      assert details.module == Foo
      assert details.function == :bar
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

      refute Process.whereis(:cover_server)
      assert {:ok, _} = ScopeResolver.resolve("Foo", loader: loader, source_files: ["lib/foo.ex"])
      refute Process.whereis(:cover_server)
      refute File.exists?("cover")
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
end
