defmodule MutagenEx.AstCacheTest do
  @moduledoc """
  Tests for `MutagenEx.AstCache`.

  Subjects advanced (see `.spec/specs/coverage.spec.md`):

    * `mutagen.coverage.r6` — single-load, immutable cache; AST + verbatim
      source kept together.
    * `mutagen.coverage.s6` — `get/2` returns the same entry the cache was
      built with.
    * `mutagen.coverage.r9` — categorised load: `opts[:categories]` is
      input-only diagnostic metadata; entry shape is unchanged.
    * `mutagen.coverage.s9a` — categorised input produces a cache
      byte-identical to the same flat load without `:categories`.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias MutagenEx.AstCache

  @sample_module ~S"""
  defmodule Sample.Mod do
    def hello, do: :ok

    def add(a, b) do
      a + b
    end
  end
  """

  describe "load/2 — r6: single-load, immutable, AST + verbatim source" do
    test "returns ast + source byte-identical to the loader's output" do
      reader = fn "synthetic/sample.ex" -> @sample_module end

      assert {:ok, cache} = AstCache.load(["synthetic/sample.ex"], reader: reader)

      assert {:ok, {ast, source}} = AstCache.get(cache, "synthetic/sample.ex")
      assert source == @sample_module

      assert is_tuple(ast)

      # AST must carry line/column metadata for downstream slicing.
      assert {:defmodule, meta, _args} = ast
      assert Keyword.has_key?(meta, :line)
    end

    test "calls the reader exactly once per file (single-load contract)" do
      counter = :counters.new(1, [])

      reader = fn _file ->
        :counters.add(counter, 1, 1)
        @sample_module
      end

      files = ["a.ex", "b.ex"]

      assert {:ok, cache} = AstCache.load(files, reader: reader)
      assert map_size(cache) == 2

      assert :counters.get(counter, 1) == 2
    end

    test "byte-identical source: arbitrary whitespace and unicode preserved" do
      weird =
        "defmodule Sample.Unicode do\r\n  @greeting \"héllo — 𝕨orld\"\n  def g, do: @greeting\nend\n"

      reader = fn _ -> weird end

      assert {:ok, cache} = AstCache.load(["w.ex"], reader: reader)
      assert {:ok, {_ast, source}} = AstCache.get(cache, "w.ex")
      assert source == weird
      assert :crypto.hash(:sha256, source) == :crypto.hash(:sha256, weird)
    end

    test "immutable shape: returned cache is a plain map with no put/update API" do
      reader = fn _ -> @sample_module end

      assert {:ok, cache} = AstCache.load(["x.ex"], reader: reader)

      # Caller can only `get/2`; the module exposes no `put/3` or
      # `update/3`. We assert this at the module level since it's the
      # contract that prevents post-load mutation.
      refute function_exported?(AstCache, :put, 3)
      refute function_exported?(AstCache, :update, 3)
      refute function_exported?(AstCache, :delete, 2)

      # And the value is just a map — callers could in theory `Map.put`
      # into it, but that produces a different map; nothing in our API
      # writes back to the same reference.
      assert is_map(cache)
      assert AstCache.files(cache) == ["x.ex"]
    end
  end

  describe "load/2 — failure paths" do
    test "returns :file_read_failed when the reader raises" do
      reader = fn _ ->
        raise File.Error, action: "read file", path: "missing.ex", reason: :enoent
      end

      assert {:error, :file_read_failed, details} = AstCache.load(["missing.ex"], reader: reader)
      assert details.file == "missing.ex"
      assert is_binary(details.message)
    end

    test "returns :parse_error when source is not valid Elixir" do
      reader = fn _ -> "defmodule Broken do\n  def x(, do: 1\nend\n" end

      assert {:error, :parse_error, details} = AstCache.load(["broken.ex"], reader: reader)
      assert details.file == "broken.ex"
      assert is_integer(details.line)
      assert is_binary(details.message)
    end

    test "halts on the first failure (subsequent files not read)" do
      counter = :counters.new(1, [])

      reader = fn
        "broken.ex" ->
          :counters.add(counter, 1, 1)
          "defmodule Broken do\n  def x(, do: 1\nend\n"

        "ok.ex" ->
          :counters.add(counter, 1, 1)
          @sample_module
      end

      assert {:error, :parse_error, _} =
               AstCache.load(["broken.ex", "ok.ex"], reader: reader)

      # `ok.ex` must not have been read after the parse failure halted the
      # reduction.
      assert :counters.get(counter, 1) == 1
    end
  end

  describe "get/2 + files/1" do
    test "round-trips through get/2 — s6" do
      reader = fn "f.ex" -> @sample_module end

      assert {:ok, cache} = AstCache.load(["f.ex"], reader: reader)

      assert {:ok, {ast1, source1}} = AstCache.get(cache, "f.ex")
      assert {:ok, {ast2, source2}} = AstCache.get(cache, "f.ex")

      assert ast1 == ast2
      assert source1 == source2
      assert source1 == @sample_module
    end

    test "get/2 returns :error for absent files" do
      reader = fn _ -> @sample_module end
      assert {:ok, cache} = AstCache.load(["a.ex"], reader: reader)
      assert AstCache.get(cache, "missing.ex") == :error
    end

    test "files/1 lists the loaded files" do
      reader = fn _ -> @sample_module end
      assert {:ok, cache} = AstCache.load(["a.ex", "b.ex", "c.ex"], reader: reader)
      assert Enum.sort(AstCache.files(cache)) == ["a.ex", "b.ex", "c.ex"]
    end
  end

  describe "load/2 — r9: categorised input (input-only diagnostic metadata)" do
    test "s9a: categorised load produces a cache byte-identical to the flat load" do
      reader = fn _ -> @sample_module end

      files = ["lib/a.ex", "test/a_test.exs"]

      categories = %{scope: ["lib/a.ex"], test: ["test/a_test.exs"]}

      assert {:ok, with_cat} = AstCache.load(files, reader: reader, categories: categories)
      assert {:ok, without_cat} = AstCache.load(files, reader: reader)

      # The entry shape must NOT carry a category tag: each value is a
      # 2-tuple. If a future refactor expanded entries to 3-tuples to
      # carry a category, the line below would fail (tuple_size mismatch
      # on the match below).
      Enum.each(files, fn f ->
        assert {:ok, {ast, source}} = AstCache.get(with_cat, f)
        assert is_binary(source)
        assert tuple_size({ast, source}) == 2
      end)

      # Byte-identical to the no-categories load — categorisation must
      # NOT change what we stored. If the implementation ever started
      # threading the category into the entry (or the source text),
      # this equality would break.
      assert with_cat == without_cat
    end

    test "entry shape stays {ast, source} regardless of category presence (r9)" do
      reader = fn _ -> @sample_module end

      assert {:ok, cache} =
               AstCache.load(["x.ex"], reader: reader, categories: %{scope: ["x.ex"]})

      assert {:ok, entry} = AstCache.get(cache, "x.ex")

      # Exactly a 2-tuple of {ast, source}. Match guards this against
      # a 3-tuple category-tagged shape.
      assert {_ast, source} = entry
      assert is_binary(source)
      assert source == @sample_module
    end

    test "reader is still called exactly once per file when :categories is set" do
      counter = :counters.new(1, [])

      reader = fn _ ->
        :counters.add(counter, 1, 1)
        @sample_module
      end

      files = ["lib/a.ex", "test/b_test.exs"]

      assert {:ok, _cache} =
               AstCache.load(files,
                 reader: reader,
                 categories: %{scope: ["lib/a.ex"], test: ["test/b_test.exs"]}
               )

      # No double-read. Categorisation is metadata only; it does not
      # trigger any extra read pass.
      assert :counters.get(counter, 1) == 2
    end

    test "load/2 ignores a malformed :categories value (does not crash)" do
      reader = fn _ -> @sample_module end

      # Non-map value should be silently ignored — :categories is
      # advisory diagnostic metadata, not part of the load contract.
      assert {:ok, _cache} =
               AstCache.load(["x.ex"], reader: reader, categories: :not_a_map)
    end

    test "load/2 emits no debug log for category diagnostics" do
      reader = fn _ -> @sample_module end

      log =
        capture_log([level: :debug], fn ->
          assert {:ok, _cache} =
                   AstCache.load(["x.ex"],
                     reader: reader,
                     categories: %{scope: ["x.ex"]}
                   )
        end)

      assert log == ""
    end
  end
end
