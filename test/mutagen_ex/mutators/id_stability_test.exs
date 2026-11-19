defmodule MutagenEx.Mutators.IdStabilityTest do
  use ExUnit.Case, async: true

  alias MutagenEx.{Ast, AstCache, MutationEnumerator, Mutators, ScopeResolver}

  @sample_file "lib/id_sample.ex"
  @body """
    def exercise(x,y) when is_integer(x) and x > 0 do
      value=pick((x+1)*y) + System.schedulers_online
      value |> first() |> second()
      case lookup(value) do
        :a -> {:ok, x}
        _ -> {:error, y}
      end

      with {:ok,a} <- lookup(x), {:ok,b} <- lookup(y) do
        if a==b do
          1
        else
          0
        end
      else
        _ -> :missing
      end
    end
  """

  @tag spec: "mutagen.mutators.r4"
  test "line shifts and formatter reflow preserve IDs across the entire catalog" do
    source = module_source(@body)
    original = entries(enumerate(source))
    ids = MapSet.new(original, & &1.id)
    assert MapSet.new(original, & &1.mutator) == MapSet.new(Mutators.names())

    for prefix <- ["", "\n\n", "  # before\n", "  def fresh(z), do: z + 1\n"],
        suffix <- ["", "\n\n", "  # after\n", "  def later(z), do: z + 1\n"],
        line_length <- [24, 50, 98] do
      changed = module_source(prefix <> @body <> suffix)

      formatted =
        changed |> Code.format_string!(line_length: line_length) |> IO.iodata_to_binary()

      shifted_ids = changed |> enumerate() |> entries() |> MapSet.new(& &1.id)
      formatted_ids = formatted |> enumerate() |> entries() |> MapSet.new(& &1.id)

      assert MapSet.subset?(ids, shifted_ids), "lost IDs for:\n#{changed}"
      assert formatted_ids == shifted_ids, "formatter changed IDs for:\n#{changed}"

      inserted_defs = Enum.count([prefix, suffix], &String.contains?(&1, "def "))
      assert MapSet.size(shifted_ids) == MapSet.size(ids) + 2 * inserted_defs
    end

    assert entries(enumerate(source)) == original
  end

  @tag spec: "mutagen.mutators.r4"
  test "renaming a definition changes all of its IDs and expression edits change the affected ID" do
    original = module_source(@body) |> enumerate() |> entries()
    renamed = module_source(String.replace(@body, "def exercise(", "def renamed("))

    assert MapSet.disjoint?(
             MapSet.new(original, & &1.id),
             MapSet.new(entries(enumerate(renamed)), & &1.id)
           )

    for {mutator, before, after_edit} <- [
          {:arith, "x+1", "x-1"},
          {:compare, "a==b", "a != b"},
          {:boolean, "and x", "or x"},
          {:literal, "x+1", "x+true"},
          {:with_swap, "lookup(y) do", "lookup(x) do"},
          {:case_drop, "case lookup(value)", "case lookup(x)"},
          {:pipeline, "first()", "other()"},
          {:result_tuple, "{:ok, x}", "{:ok, y}"},
          {:else_removal, "1\n      else", "0\n      else"},
          {:guard_drop, "x > 0", "x >= 0"}
        ] do
      assert String.contains?(@body, before), "missing expression for #{mutator}"

      edited =
        module_source(String.replace(@body, before, after_edit)) |> enumerate() |> entries()

      original_ids = ids_for(original, mutator)
      edited_ids = ids_for(edited, mutator)
      refute MapSet.subset?(original_ids, edited_ids), "#{mutator} kept the old ID"
      refute MapSet.subset?(edited_ids, original_ids), "#{mutator} lacked a new ID"
    end
  end

  @tag spec: ["mutagen.mutators.r3", "mutagen.mutation_enumeration.r4"]
  test "identical expressions get ordinals across the body and clauses, before coverage filtering" do
    source = """
    defmodule IdSample do
      def first(x) when is_integer(x) do
        x + 1
        fn -> x + 1 end
      end

      def first(x), do: x + 1
      def second(x), do: x + 1
    end
    """

    sites = arith_sites(enumerate(source))
    {first, second} = Enum.split(sites, 3)

    node = {:+, [], [{:x, [], nil}, 1]}

    for {site, ordinal} <- Enum.with_index(first) do
      assert site.function == "IdSample.first/1"

      assert site.id ==
               Mutators.site_id(@sample_file, {{IdSample, :first, 1}, node, ordinal}, :arith)
    end

    assert [%{function: "IdSample.second/1", id: second_id}] = second
    assert second_id == Mutators.site_id(@sample_file, {{IdSample, :second, 1}, node, 0}, :arith)
    assert sites |> Enum.uniq_by(& &1.id) |> length() == 4

    only_covered = Enum.at(first, 2)
    assert arith_sites(enumerate(source, :all, [only_covered.line])) == [only_covered]
  end

  @tag spec: ["mutagen.mutation_enumeration.r4", "mutagen.ast.r2", "mutagen.scope_resolution.r10"]
  test "tracks nested modules, all named definition kinds, guards, defaults and attributes" do
    source = ~S"""
    defmodule IdSample do
      @outer 1 + 1

      def public(x \\ 1 + 1) when x + 1 > 0, do: x + 1
      defp private, do: 1 + 1

      defmodule Nested do
        @inner 1 + 1
        defmacro expand(x), do: x + 1
        defmacrop expand_private(x), do: x + 1
      end

      defmodule Elixir.IdAbsolute do
        def zero, do: 1 + 1
      end

      defmodule __MODULE__.Explicit do
        def zero, do: 1 + 1
      end

      defmodule :id_atom do
        def zero, do: 1 + 1
      end
    end
    """

    {:ok, scopes} = ScopeResolver.resolve(@sample_file, loader: fn _ -> source end)

    assert Enum.map(scopes, & &1.module) == [
             IdSample,
             IdSample.Nested,
             IdAbsolute,
             IdSample.Explicit,
             :id_atom
           ]

    {:ok, cache} = AstCache.load([@sample_file], reader: fn _ -> source end)
    {:ok, {ast, _}} = AstCache.get(cache, @sample_file)
    assert {:ok, {:def, _, _}} = Ast.find_module_body(ast, "IdAbsolute")
    assert {:ok, {:def, _, _}} = Ast.find_module_body(ast, "IdSample.Explicit")
    assert :not_found = Ast.find_module_body(ast, "IdSample.IdAbsolute")

    all = arith_sites(enumerate(source))

    assert Enum.map(all, & &1.function) == [
             nil,
             "IdSample.public/1",
             "IdSample.public/1",
             "IdSample.public/1",
             "IdSample.private/0",
             nil,
             "IdSample.Nested.expand/1",
             "IdSample.Nested.expand_private/1",
             "IdAbsolute.zero/0",
             "IdSample.Explicit.zero/0",
             ":id_atom.zero/0"
           ]

    assert length(Enum.uniq_by(all, & &1.id)) == length(all)

    nested_only = arith_sites(enumerate(source, [IdSample.Nested]))

    assert nested_only == Enum.slice(all, 5, 3)

    assert arith_sites(enumerate(source, [IdSample.Nested, IdSample, IdSample.Nested])) ==
             nested_only ++ (all -- nested_only)
  end

  @tag spec: "mutagen.mutators.r3"
  test "compiler resolution metadata stays in the identity while spelling and positions drop" do
    identity = fn source ->
      {:ok, cache} = AstCache.load([@sample_file], reader: fn _ -> source end)
      {:ok, {ast, _}} = AstCache.get(cache, @sample_file)
      Mutators.identity_node(ast)
    end

    assert identity.("pick ~r/foo/i") == identity.("\n\npick(~r|foo|i)")
    assert identity.("pick ~S\"\"\"\n  foo\n  \"\"\"") == identity.("pick(~S|foo\n|)")
    assert identity.("pick %{call() => 1}") == identity.("\npick( %{call( ) => 1} )")
    assert identity.("pick +1") == identity.("pick(+1)")
    refute identity.("pick ~r/foo/i") == identity.("pick ~r/foo/")
    refute identity.("pick ~r/foo/") == identity.("pick ~S/foo/")
    assert identity.("pick Kernel.node") == identity.("pick Kernel.node()")
    assert identity.("pick :erlang.node") == identity.("pick :erlang.node()")
    assert identity.("pick __MODULE__.value") == identity.("pick __MODULE__.value()")
    refute identity.("pick x.foo") == identity.("pick x.foo()")

    hydrated =
      {:call, [closing: [line: 3, column: 8], format: :keyword], [{:x, [counter: 10], nil}]}

    assert Mutators.identity_node(hydrated) == {:call, [], [{:x, [counter: 10], nil}]}

    refute Mutators.identity_node(hydrated) ==
             Mutators.identity_node({:call, [], [{:x, [counter: 11], nil}]})
  end

  @tag spec: "mutagen.mutators.r3"
  test "two expressions that collide under the full phash2 range have distinct IDs" do
    source = """
    defmodule Probe do
      def f(x), do: {x + 9264, x + 11128}
    end
    """

    [left, right] = arith_sites(enumerate(source))
    assert left.id != right.id
  end

  defp module_source(body), do: "defmodule IdSample do\n#{body}end\n"

  defp enumerate(source, selected \\ :all, covered \\ nil) do
    {:ok, cache} = AstCache.load([@sample_file], reader: fn _ -> source end)
    {:ok, {ast, _}} = AstCache.get(cache, @sample_file)
    {:ok, scopes} = ScopeResolver.resolve(@sample_file, loader: fn _ -> source end)

    scopes =
      case selected do
        :all -> scopes
        modules -> Enum.map(modules, fn module -> Enum.find(scopes, &(&1.module == module)) end)
      end

    covered = covered || 1..(1 + length(String.split(source, "\n")))

    MutationEnumerator.enumerate(%{@sample_file => ast}, scopes, %{
      @sample_file => MapSet.new(covered)
    })
  end

  defp entries(result) do
    result.sites ++ Enum.map(result.skipped, &%{id: &1.site_id, mutator: &1.mutator})
  end

  defp ids_for(entries, mutator) do
    entries |> Enum.filter(&(&1.mutator == mutator)) |> MapSet.new(& &1.id)
  end

  defp arith_sites(result), do: Enum.filter(result.sites, &(&1.mutator == :arith))
end
