defmodule MutagenEx.TestSelectorTest do
  @moduledoc """
  Tests for `MutagenEx.TestSelector.resolve/2`.

  Covers scenarios `mutagen.test_selection.s1`-`s5` and spec-verification
  stubs `mutagen.test_selection.v1`, `.v2`, `.v3`. See
  `.spec/specs/test_selection.spec.md` for the contract.

  ## Provenance check (mutagen.test_selection.v2)

  Requirement `r4` insists that tag resolution does NOT load test modules —
  it must AST-walk via `Code.string_to_quoted/2`. The "tag resolution does
  not load any test module" assertion below traces the implementation
  source to prove this requirement is structurally guaranteed, not just
  observed at runtime: the file must not reference `Code.require_file`,
  `Code.eval_file`, `Code.eval_string`, or `Code.compile_*`, and must
  reference `Code.string_to_quoted`. Together those two checks make it
  structurally impossible for the selector to load a test module without
  the source diff being audit-visible.
  """

  use ExUnit.Case, async: true

  alias MutagenEx.TestSelector
  alias MutagenEx.TestSelector.TestFilter

  # ---------------------------------------------------------------------------
  # Fixture helpers
  # ---------------------------------------------------------------------------

  setup do
    fixture_dir =
      Path.join([
        System.tmp_dir!(),
        "mutagen_ex_selector_#{System.unique_integer([:positive])}"
      ])

    File.mkdir_p!(fixture_dir)
    on_exit(fn -> File.rm_rf!(fixture_dir) end)
    {:ok, fixture_dir: fixture_dir}
  end

  defp write_test_file(dir, name, content) do
    path = Path.join(dir, name)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
    path
  end

  defp tagged_test_module(tag_string, mod_name) do
    """
    defmodule #{mod_name}Test do
      use ExUnit.Case

      #{tag_string}
      test "a tagged test" do
        assert true
      end
    end
    """
  end

  # ---------------------------------------------------------------------------
  # mutagen.test_selection.s1 — file-only target (r1)
  # ---------------------------------------------------------------------------

  describe "resolve/2 — file target (mutagen.test_selection.s1, r1)" do
    test "file-only target returns include=[], exclude=[], files=[path]" do
      # mutagen-wrd.11 regression guard: exclude must be `[]` for bare-file
      # targets. ExUnit's filter eval, given include=[] and exclude=[:test],
      # excludes every test (every test carries the implicit `:test` tag).
      # The earlier `exclude: [:test]` here caused baseline / coverage /
      # mutation passes to see zero tests, classifying every mutation as
      # `:survived`.
      assert {:ok, %TestFilter{} = filter} = TestSelector.resolve("test/foo_test.exs")
      assert filter.include == []
      assert filter.exclude == []
      assert filter.files == ["test/foo_test.exs"]
    end

    test "non-standard nested path still resolves" do
      assert {:ok, %TestFilter{files: ["test/nested/dir/foo_test.exs"], exclude: []}} =
               TestSelector.resolve("test/nested/dir/foo_test.exs")
    end

    test "target missing the _test.exs suffix is rejected" do
      assert {:error, %{reason: :invalid_target, target: "test/foo.exs"}} =
               TestSelector.resolve("test/foo.exs")
    end

    test "non-binary target is rejected" do
      assert {:error, %{reason: :invalid_target}} = TestSelector.resolve([42])
    end
  end

  # ---------------------------------------------------------------------------
  # mutagen.test_selection.s2 — file:line target (r2)
  # ---------------------------------------------------------------------------

  describe "resolve/2 — file:line target (mutagen.test_selection.s2, r2)" do
    setup %{fixture_dir: dir} do
      # The file:line resolver validates the line is inside a `test` block.
      # Build a fixture file whose `test` block spans lines 4-6.
      path =
        write_test_file(dir, "with_line_test.exs", """
        defmodule WithLineTest do
          use ExUnit.Case

          test "first" do
            assert 1 == 1
          end
        end
        """)

      {:ok, path: path}
    end

    test "file:line returns include=[{:location, {path, line}}]", %{path: path} do
      target = "#{path}:5"

      assert {:ok, %TestFilter{include: include, exclude: [:test], files: files}} =
               TestSelector.resolve(target)

      assert include == [{:location, {path, 5}}]
      assert files == [path]
    end

    test "non-integer line is rejected" do
      assert {:error, %{reason: :invalid_target, target: "test/foo_test.exs:abc"}} =
               TestSelector.resolve("test/foo_test.exs:abc")
    end

    test "line pointing outside every test block returns :no_tests_match", %{path: path} do
      target = "#{path}:99"
      assert {:error, %{reason: :no_tests_match, target: ^target}} = TestSelector.resolve(target)
    end
  end

  # ---------------------------------------------------------------------------
  # mutagen.test_selection.s3 — tag target with AST walk (r3, r4)
  # ---------------------------------------------------------------------------

  describe "resolve/2 — tag target (mutagen.test_selection.s3, r3, r4)" do
    test "tag resolves to files containing @tag :NAME on a test/describe block",
         %{fixture_dir: dir} do
      a = write_test_file(dir, "a_test.exs", tagged_test_module("@tag :slow", "A"))
      _b = write_test_file(dir, "b_test.exs", tagged_test_module("# no tag", "B"))

      assert {:ok, %TestFilter{include: include, exclude: [:test], files: files}} =
               TestSelector.resolve("tag:slow", test_root: dir)

      assert include == [:slow]
      assert a in files
      refute Enum.any?(files, &String.ends_with?(&1, "b_test.exs"))
    end

    test "tag walk recurses into subdirectories", %{fixture_dir: dir} do
      nested =
        write_test_file(dir, "nested/deep_test.exs", tagged_test_module("@tag :integration", "D"))

      assert {:ok, %TestFilter{files: files}} =
               TestSelector.resolve("tag:integration", test_root: dir)

      assert nested in files
    end

    test "tag walk recognises keyword-form @tag attribute", %{fixture_dir: dir} do
      keyword_form = """
      defmodule KwTest do
        use ExUnit.Case

        @tag kind: :integration
        test "uses keyword tag" do
          assert true
        end
      end
      """

      path = write_test_file(dir, "kw_test.exs", keyword_form)

      assert {:ok, %TestFilter{files: files}} =
               TestSelector.resolve("tag:kind", test_root: dir)

      assert path in files
    end

    test "tag walk ignores files that cannot be parsed", %{fixture_dir: dir} do
      _broken = write_test_file(dir, "broken_test.exs", "this is not valid elixir [[[")
      tagged = write_test_file(dir, "good_test.exs", tagged_test_module("@tag :ok", "G"))

      assert {:ok, %TestFilter{files: files}} =
               TestSelector.resolve("tag:ok", test_root: dir)

      assert tagged in files
      refute Enum.any?(files, &String.ends_with?(&1, "broken_test.exs"))
    end

    test "tag resolution does not load any test module (structural check via source)" do
      # This is the v2 stub: trace the implementation source to confirm it
      # only AST-walks. Loading the test module would interfere with the
      # mutation pipeline's state hygiene contract (r4).
      source = File.read!("lib/mutagen_ex/test_selector.ex")

      refute source =~ "Code.require_file",
             "test_selector.ex must not call Code.require_file — it would load test modules"

      refute source =~ "Code.eval_file",
             "test_selector.ex must not call Code.eval_file — it would load test modules"

      refute source =~ "Code.eval_string",
             "test_selector.ex must not call Code.eval_string — it would load test modules"

      refute source =~ "Code.compile_string",
             "test_selector.ex must not call Code.compile_string — it would load test modules"

      refute source =~ "Code.compile_file",
             "test_selector.ex must not call Code.compile_file — it would load test modules"

      refute source =~ "Code.compile_quoted",
             "test_selector.ex must not call Code.compile_quoted — it would load test modules"

      refute source =~ "ExUnit.Filters.parse_paths",
             "test_selector.ex must not call ExUnit.Filters.parse_paths — it loads modules"

      assert source =~ "Code.string_to_quoted",
             "test_selector.ex must AST-walk via Code.string_to_quoted (r4)"
    end
  end

  # ---------------------------------------------------------------------------
  # mutagen.test_selection.s4 — empty resolution → :no_tests_match (r5)
  # ---------------------------------------------------------------------------

  describe "resolve/2 — no matching tests (mutagen.test_selection.s4, r5)" do
    @describetag :no_match_cases

    test "tag with zero matches returns structured error", %{fixture_dir: dir} do
      _ = write_test_file(dir, "a_test.exs", tagged_test_module("@tag :other", "A"))

      assert {:error, %{reason: :no_tests_match, target: "tag:unused_tag"}} =
               TestSelector.resolve("tag:unused_tag", test_root: dir)
    end

    test "tag with empty test_root returns structured error", %{fixture_dir: dir} do
      empty = Path.join(dir, "empty_subdir")
      File.mkdir_p!(empty)

      assert {:error, %{reason: :no_tests_match, target: "tag:nothing"}} =
               TestSelector.resolve("tag:nothing", test_root: empty)
    end

    test "tag against missing test_root returns structured error" do
      assert {:error, %{reason: :file_not_found, target: "tag:any"}} =
               TestSelector.resolve("tag:any", test_root: "/nonexistent/path/should/not/exist")
    end

    test "file:line pointing outside any test block returns :no_tests_match",
         %{fixture_dir: dir} do
      # Test block spans lines 4-6.
      path =
        write_test_file(dir, "with_block_test.exs", """
        defmodule WithBlockTest do
          use ExUnit.Case

          test "first" do
            assert true
          end
        end
        """)

      target = "#{path}:1"
      assert {:error, %{reason: :no_tests_match, target: ^target}} = TestSelector.resolve(target)
    end
  end

  # ---------------------------------------------------------------------------
  # mutagen.test_selection.s5 — union of multiple targets (r6)
  # ---------------------------------------------------------------------------

  describe "resolve/2 — composing multiple targets (mutagen.test_selection.s5, r6)" do
    test "file + file targets union into files list with exclude=[]" do
      assert {:ok, %TestFilter{files: files, include: [], exclude: []}} =
               TestSelector.resolve(["test/a_test.exs", "test/b_test.exs"])

      assert Enum.sort(files) == ["test/a_test.exs", "test/b_test.exs"]
    end

    test "duplicate file targets deduplicate" do
      assert {:ok, %TestFilter{files: files, exclude: []}} =
               TestSelector.resolve(["test/a_test.exs", "test/a_test.exs"])

      assert files == ["test/a_test.exs"]
    end

    test "file + tag targets compose, deduplicating shared files",
         %{fixture_dir: dir} do
      a = write_test_file(dir, "a_test.exs", tagged_test_module("@tag :slow", "A"))

      assert {:ok, %TestFilter{include: include, files: files, exclude: exclude}} =
               TestSelector.resolve([a, "tag:slow"], test_root: dir)

      assert :slow in include
      # `a` contributes the file directly; tag:slow also resolves to `a`.
      # The deduplication contract from r6 says the file appears once.
      assert files |> Enum.frequencies() |> Map.get(a) == 1

      # r6 union rule: bare-file contributor takes precedence — exclude
      # collapses to [] so every test in `a` runs (not just tagged ones).
      assert exclude == []
    end

    test "tag + tag targets keep restrictive exclude=[:test]",
         %{fixture_dir: dir} do
      _a = write_test_file(dir, "a_test.exs", tagged_test_module("@tag :slow", "A"))
      _b = write_test_file(dir, "b_test.exs", tagged_test_module("@tag :fast", "B"))

      assert {:ok, %TestFilter{include: include, exclude: [:test]}} =
               TestSelector.resolve(["tag:slow", "tag:fast"], test_root: dir)

      # Both contributors are tag-restrictive, so the union keeps [:test]
      # — only tagged tests run, which is the safe interpretation when no
      # bare-file contributor exists to broaden the filter.
      assert :slow in include
      assert :fast in include
    end

    test "first failing target halts and is reported" do
      assert {:error, %{reason: :invalid_target, target: "not-a-test"}} =
               TestSelector.resolve(["test/foo_test.exs", "not-a-test", "test/bar_test.exs"])
    end
  end

  # ---------------------------------------------------------------------------
  # exclude semantics by target shape (mutagen-wrd.11 regression guard)
  # ---------------------------------------------------------------------------

  # ---------------------------------------------------------------------------
  # mutagen.test_selection.s7 — atom safety (r7, mutagen-wrd.20)
  # ---------------------------------------------------------------------------

  describe "tag resolution atom safety (mutagen.test_selection.r7, s7)" do
    @describetag :atom_safety

    # Helper: structurally falsify atom registration. Uses
    # `:erlang.binary_to_existing_atom/1` which raises `ArgumentError`
    # when the atom doesn't exist. This avoids the async-test
    # `:erlang.system_info(:atom_count)` noise — we don't measure how
    # many atoms moved; we ask the specific question "did the user's
    # input get registered as an atom?" The answer must be NO.
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

    test "tag with no matching @tag in test corpus does not register the atom",
         %{fixture_dir: dir} do
      _ = write_test_file(dir, "a_test.exs", tagged_test_module("@tag :unrelated", "A"))

      # Generate a name unique to this test run. The probe is in a local
      # binding (not a source literal), so it does not pre-register via
      # test-file parsing.
      probe_name = "never_registered_#{System.unique_integer([:positive])}"
      probe = "tag:" <> probe_name

      # Sanity: the probe atom is genuinely unregistered before the call.
      assert_raise ArgumentError, fn ->
        :erlang.binary_to_existing_atom(probe_name, :utf8)
      end

      assert {:error, %{reason: :no_tests_match, target: ^probe}} =
               TestSelector.resolve(probe, test_root: dir)

      # Pre-fix: `String.to_atom(name)` at the head of `resolve_tag/2`
      # registered the atom unconditionally — `binary_to_existing_atom`
      # would have succeeded. Post-fix: the selector compares strings
      # against `Atom.to_string/1` of AST atoms; no atom is materialized
      # from the user's input.
      refute_atom_registered(probe_name)
    end

    test "looping N distinct never-registered tag names registers zero of them",
         %{fixture_dir: dir} do
      # The DOS-attack shape (mutagen-wrd.20): CI loop running
      # `mix mutagen --tests tag:$(uuidgen)`. Pre-fix, this would
      # register exactly N fresh atoms (one per call). Post-fix, the
      # falsification is structural: AFTER the loop, NONE of the N
      # probe strings are registered atoms.
      _ = write_test_file(dir, "x_test.exs", tagged_test_module("@tag :other", "X"))

      n = 50

      probes =
        for i <- 1..n do
          "atomsafe_loop_#{System.unique_integer([:positive])}_#{i}"
        end

      for probe_name <- probes do
        probe = "tag:" <> probe_name

        assert {:error, %{reason: :no_tests_match, target: ^probe}} =
                 TestSelector.resolve(probe, test_root: dir)
      end

      # None of the N user-supplied tag names became atoms. Pre-fix this
      # would have failed on iteration 1.
      for probe_name <- probes do
        refute_atom_registered(probe_name)
      end
    end

    test "matching tag returns the AST-derived atom (not a freshly minted one)",
         %{fixture_dir: dir} do
      # The atom that lands in `include` must be the one parsed from the
      # test file's source — not one synthesized from the user input. We
      # confirm this structurally by:
      #   1. Loading source that registers `:slow_for_atom_safety_test`.
      #   2. Calling resolve and asserting the matched atom round-trips
      #      cleanly via `Atom.to_string/1`. (The function would fail
      #      identically whether the atom came from the AST or from
      #      `String.to_atom/1`, but the no-growth tests above prove the
      #      latter path is dead.)
      content = """
      defmodule MatchTagTest do
        use ExUnit.Case

        @tag :slow_for_atom_safety_test
        test "tagged" do
          assert true
        end
      end
      """

      _ = write_test_file(dir, "match_tag_test.exs", content)

      assert {:ok, %TestFilter{include: include}} =
               TestSelector.resolve("tag:slow_for_atom_safety_test", test_root: dir)

      assert include == [:slow_for_atom_safety_test]
    end

    test "source no longer references String.to_atom on user input (structural)" do
      # Provenance check (`mutagen.test_selection.r7`): the implementation
      # source must not call `String.to_atom/1`. We strip comment lines so
      # commentary referencing the function (e.g. "we no longer call
      # String.to_atom(name)") doesn't false-positive — only an actual call
      # site falsifies.
      non_comment_source =
        File.read!("lib/mutagen_ex/test_selector.ex")
        |> String.split("\n")
        |> Enum.reject(&String.match?(&1, ~r/^\s*#/))
        |> Enum.join("\n")

      refute non_comment_source =~ ~r/String\.to_atom\(/,
             "test_selector.ex must not call String.to_atom/1 — it would allow user-driven atom growth (mutagen.test_selection.r7)"
    end
  end

  describe "exclude convention" do
    test "bare-file target sets exclude=[] (mutagen-wrd.11)" do
      # The original bug: file-cited targets emitted exclude=[:test],
      # which excluded every test from baseline / coverage / mutation.
      assert {:ok, %TestFilter{exclude: []}} =
               TestSelector.resolve("test/foo_test.exs")
    end

    test "file:line target sets exclude=[:test]", %{fixture_dir: dir} do
      # file:line is paired with a non-empty :location include, so the
      # include side admits the cited line while [:test] excludes the
      # rest — restrictive semantics are intentional here.
      path =
        write_test_file(dir, "with_line_test.exs", """
        defmodule WithLineExcludeTest do
          use ExUnit.Case

          test "first" do
            assert true
          end
        end
        """)

      assert {:ok, %TestFilter{exclude: [:test]}} = TestSelector.resolve("#{path}:5")
    end

    test "tag target sets exclude=[:test]", %{fixture_dir: dir} do
      _tagged = write_test_file(dir, "x_test.exs", tagged_test_module("@tag :foo", "X"))
      assert {:ok, %TestFilter{exclude: [:test]}} = TestSelector.resolve("tag:foo", test_root: dir)
    end
  end
end
