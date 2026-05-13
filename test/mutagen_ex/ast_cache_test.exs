defmodule MutagenEx.AstCacheTest do
  @moduledoc """
  Tests for `MutagenEx.AstCache`.

  Subjects advanced (see `.spec/specs/coverage.spec.md`):

    * `mutagen.coverage.r6` — single-load, immutable cache; AST + verbatim
      source kept together.
    * `mutagen.coverage.s6` — `get/2` returns the same entry the cache was
      built with.
  """

  use ExUnit.Case, async: false

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
end
