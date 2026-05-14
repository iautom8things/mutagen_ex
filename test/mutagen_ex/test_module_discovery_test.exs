defmodule MutagenEx.TestModuleDiscoveryTest do
  @moduledoc """
  Tests for `MutagenEx.TestModuleDiscovery.discover/1` — the production
  derivation of `MutationRunner`'s `test_modules` payload from the
  resolved `test_filter.files`.

  ## What these tests prove

  Each test calls `discover/1` against an on-disk source file (or files)
  in a per-test tmp directory and asserts the resulting list of
  `{module, cfg}` tuples. The shape of `cfg` is locked because
  `MutationLoop` re-registers each entry with `ExUnit.Server.add_module/2`,
  which consumes that exact map shape (validated by the S2 spike).

  Coverage:
    - single defmodule per file
    - multiple defmodule per file (source order preserved)
    - multiple files (concat, per-file source order preserved)
    - dotted alias (e.g. `MyApp.FooTest`) resolves to the full atom
    - empty file list -> empty result
    - unreadable file (does not exist) -> no entries, no raise
    - unparseable file -> no entries, no raise
    - non-test source file (a real `lib/` module) -> still returns its
      defmodule entry. The discovery function does not filter by
      `_test.exs` suffix; the caller (`Mix.Tasks.Mutagen`) is expected
      to pass `test_filter.files`, which is already filtered upstream.
    - nested defmodule blocks are picked up alongside their parents.
  """

  use ExUnit.Case, async: true

  alias MutagenEx.TestModuleDiscovery

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "mutagen_ex_disc_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    {:ok, dir: dir}
  end

  describe "discover/1 — happy paths" do
    test "empty list returns empty list" do
      assert TestModuleDiscovery.discover([]) == []
    end

    test "single defmodule in one file returns one entry", %{dir: dir} do
      file = Path.join(dir, "a_test.exs")
      File.write!(file, """
      defmodule SomeATest do
        use ExUnit.Case
        test "x", do: :ok
      end
      """)

      assert TestModuleDiscovery.discover([file]) ==
               [{SomeATest, %{async?: false, group: nil, parameterize: nil}}]
    end

    test "multiple defmodules in one file return entries in source order", %{dir: dir} do
      file = Path.join(dir, "b_test.exs")
      File.write!(file, """
      defmodule FirstTest do
        use ExUnit.Case
        test "x", do: :ok
      end

      defmodule SecondTest do
        use ExUnit.Case
        test "y", do: :ok
      end

      defmodule ThirdTest do
        use ExUnit.Case
        test "z", do: :ok
      end
      """)

      assert TestModuleDiscovery.discover([file]) == [
               {FirstTest, default_cfg()},
               {SecondTest, default_cfg()},
               {ThirdTest, default_cfg()}
             ]
    end

    test "multiple files concatenate in caller order, preserving each file's source order",
         %{dir: dir} do
      file_a = Path.join(dir, "ca_test.exs")
      file_b = Path.join(dir, "cb_test.exs")

      File.write!(file_a, """
      defmodule CA1Test do
        use ExUnit.Case
      end

      defmodule CA2Test do
        use ExUnit.Case
      end
      """)

      File.write!(file_b, """
      defmodule CB1Test do
        use ExUnit.Case
      end
      """)

      assert TestModuleDiscovery.discover([file_a, file_b]) == [
               {CA1Test, default_cfg()},
               {CA2Test, default_cfg()},
               {CB1Test, default_cfg()}
             ]

      # And in the opposite caller order:
      assert TestModuleDiscovery.discover([file_b, file_a]) == [
               {CB1Test, default_cfg()},
               {CA1Test, default_cfg()},
               {CA2Test, default_cfg()}
             ]
    end

    test "dotted alias resolves to the full module atom", %{dir: dir} do
      file = Path.join(dir, "dotted_test.exs")
      File.write!(file, """
      defmodule MyApp.Foo.BarTest do
        use ExUnit.Case
      end
      """)

      assert TestModuleDiscovery.discover([file]) ==
               [{MyApp.Foo.BarTest, default_cfg()}]
    end

    test "non-_test.exs file still has its defmodule discovered (filtering is upstream)",
         %{dir: dir} do
      # discover/1 is filename-blind by design — the mix task feeds it
      # `test_filter.files`, which is already filtered. Asserting this
      # contract here lets the caller change its filtering rules without
      # the discovery layer being a hidden gate.
      file = Path.join(dir, "plain_lib_module.ex")
      File.write!(file, """
      defmodule SomePlainModule do
        def f, do: :ok
      end
      """)

      assert TestModuleDiscovery.discover([file]) ==
               [{SomePlainModule, default_cfg()}]
    end

    test "nested defmodule blocks are picked up alongside their parents", %{dir: dir} do
      file = Path.join(dir, "nested_test.exs")
      File.write!(file, """
      defmodule OuterTest do
        use ExUnit.Case

        defmodule InnerHelper do
          def f, do: :ok
        end

        test "x", do: :ok
      end
      """)

      # `prewalk` visits both the outer and inner defmodule blocks.
      # Both end up in the test_modules list; ExUnit.Server.add_module
      # for a non-test module is harmless (the module simply contributes
      # zero tests to `ExUnit.run/0`). The alternative — filtering by
      # `use ExUnit.Case` presence — would diverge from the e2e driver's
      # historical behavior and is out of scope for this fix.
      #
      # The inner module's atom is the *AST-level alias* (`InnerHelper`),
      # not the resolved-at-compile-time `OuterTest.InnerHelper`. This is
      # intentional — `discover/1` is a pure-AST function and does not
      # do alias resolution. ExUnit.Server.add_module/2 accepts either
      # form at the bytecode level; the cited test file's `defmodule`
      # head is what `__after_compile__` registers, so matching that
      # AST shape is the load-bearing contract.
      assert TestModuleDiscovery.discover([file]) ==
               [
                 {OuterTest, default_cfg()},
                 {InnerHelper, default_cfg()}
               ]
    end
  end

  describe "discover/1 — failure modes (return empty, never raise)" do
    test "file that does not exist contributes zero entries" do
      assert TestModuleDiscovery.discover(["/this/path/does/not/exist.exs"]) == []
    end

    test "unparseable file contributes zero entries", %{dir: dir} do
      file = Path.join(dir, "broken.exs")
      File.write!(file, "this is not valid elixir syntax (((")

      assert TestModuleDiscovery.discover([file]) == []
    end

    test "file with no defmodule contributes zero entries", %{dir: dir} do
      file = Path.join(dir, "empty.exs")
      File.write!(file, "1 + 1\n")

      assert TestModuleDiscovery.discover([file]) == []
    end

    test "broken file mixed with good files: good files still discovered", %{dir: dir} do
      good = Path.join(dir, "good_test.exs")
      bad = Path.join(dir, "bad.exs")

      File.write!(good, """
      defmodule GoodTest do
        use ExUnit.Case
      end
      """)

      File.write!(bad, "((( not parseable")

      assert TestModuleDiscovery.discover([bad, good, "/missing.exs"]) ==
               [{GoodTest, default_cfg()}]
    end
  end

  describe "discover/1 — cfg shape contract (locked to ExUnit.Server.add_module/2)" do
    # MutationLoop calls `apply(ExUnit.Server, :add_module, [mod, cfg])`
    # at lib/mutagen_ex/mutation_runner/mutation_loop.ex with whatever
    # shape we hand it. If ExUnit's expected shape ever changes, the S2
    # spike and the mutation_runner_test.exs fakes will catch the
    # regression. This test pins our side of the contract so changes to
    # either side surface as a deliberate decision.
    test "every entry's cfg is exactly %{async?: false, group: nil, parameterize: nil}",
         %{dir: dir} do
      file = Path.join(dir, "shape_test.exs")
      File.write!(file, """
      defmodule ShapeOneTest do
        use ExUnit.Case, async: true
      end

      defmodule ShapeTwoTest do
        use ExUnit.Case, async: false
      end
      """)

      results = TestModuleDiscovery.discover([file])

      assert length(results) == 2

      Enum.each(results, fn {_mod, cfg} ->
        assert cfg == %{async?: false, group: nil, parameterize: nil}
      end)
    end
  end

  defp default_cfg, do: %{async?: false, group: nil, parameterize: nil}
end
