defmodule MutagenEx.MutationRunnerPathTest do
  use ExUnit.Case, async: true

  alias MutagenEx.{AstCache, MutationEnumerator, MutationRunner, ScopeResolver}

  @moduletag spec: "mutagen.mutation_pipeline.r16"

  @tag spec: ["mutagen.mutation_pipeline.r16", "mutagen.mutation_enumeration.r4"]
  test "each fixture site changes exactly its own AST path and yields a distinct mutated file" do
    files =
      Path.wildcard("test/fixtures/**/*.{ex,exs}") ++
        Path.wildcard("priv/helper_scripts/bench_fixtures/**/*.{ex,exs}")

    assert files != []

    for file <- files do
      {ast, %{sites: sites, skipped: skipped}} = load_sites(file, File.read!(file))
      ids = Enum.map(sites, & &1.id) ++ Enum.map(skipped, & &1.site_id)
      assert length(ids) == MapSet.size(MapSet.new(ids)), "duplicate site IDs in #{file}"

      mutated_files =
        for site <- sites do
          accessors = Enum.flat_map(site.path, &access/1)

          assert get_in(ast, accessors) === site.original_ast,
                 "wrong original leaf for #{site.id}"

          assert site.original_ast !== site.mutated_ast, "no swap for #{site.id}"
          assert {:ok, changed} = MutationRunner.mutate_at_path(ast, site)
          assert changed === put_in(ast, accessors, site.mutated_ast), "wrong swap for #{site.id}"
          changed
        end

      assert length(mutated_files) == MapSet.size(MapSet.new(mutated_files)),
             "multiple sites produced the same mutant in #{file}"
    end
  end

  test "a stale path or original value fails without swapping another occurrence" do
    source = """
    defmodule PathSample do
      def run(value), do: {value + 1, value + 1}
    end
    """

    {ast, %{sites: sites}} = load_sites("lib/path_sample.ex", source)
    [first, second] = Enum.filter(sites, &(&1.mutator == :arith))
    assert {:ok, _} = MutationRunner.mutate_at_path(ast, first)

    assert {:error, :site_not_found} =
             MutationRunner.mutate_at_path(ast, %{second | path: first.path})

    assert {:error, :site_not_found} =
             MutationRunner.mutate_at_path(ast, %{second | path: [{:arg, 200}]})
  end

  defp access(:form), do: [Access.elem(0)]
  defp access(:left), do: [Access.elem(0)]
  defp access(:right), do: [Access.elem(1)]
  defp access({:arg, index}), do: [Access.elem(2), Access.at(index)]
  defp access({:elem, index}), do: [Access.at(index)]

  defp load_sites(file, source) do
    {:ok, cache} = AstCache.load([file], reader: fn ^file -> source end)
    {:ok, {ast, _}} = AstCache.get(cache, file)
    source_path = Path.rootname(file) <> ".ex"
    {:ok, scopes} = ScopeResolver.resolve(source_path, loader: fn ^source_path -> source end)
    scopes = Enum.map(scopes, &%{&1 | file: file})
    covered = MapSet.new(1..length(String.split(source, "\n")))
    {ast, MutationEnumerator.enumerate(cache, scopes, %{file => covered})}
  end
end
