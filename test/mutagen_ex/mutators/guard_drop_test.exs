defmodule MutagenEx.Mutators.GuardDropTest do
  use ExUnit.Case, async: true

  alias MutagenEx.MutationEnumerator
  alias MutagenEx.Mutators.GuardDrop
  alias MutagenEx.ScopeResolver.Scope

  describe "name/0" do
    test "name is :guard_drop" do
      assert GuardDrop.name() == :guard_drop
    end
  end

  describe "match?/1" do
    test "matches a `:when` AST node (the guard wrapper)" do
      {:def, _, [head, _]} = Code.string_to_quoted!("def f(x) when x > 0, do: x")
      assert GuardDrop.match?(head)
    end

    test "matches multi-guard form" do
      {:def, _, [head, _]} =
        Code.string_to_quoted!("def f(x) when is_integer(x) when x > 0, do: x")

      assert GuardDrop.match?(head)
    end

    test "does not match a head without guard" do
      {:def, _, [head, _]} = Code.string_to_quoted!("def f(x), do: x")
      refute GuardDrop.match?(head)
    end
  end

  describe "mutate/1" do
    test "removes the guard, returning the pattern head" do
      {:def, _, [head, _]} = Code.string_to_quoted!("def f(x) when x > 0, do: x")
      mutated = GuardDrop.mutate(head)
      # Drops the {:when, _, [head, guard]} wrapper, returns the head.
      assert {:f, _, [{:x, _, _}]} = mutated
    end
  end

  describe "validate/1" do
    @tag :validate
    @tag spec: "mutagen.mutators.r11"
    test ":ok for the head or pattern that mutate/1 returns" do
      for source <- ["def f(x) when x > 0, do: x", "case y do 42 when true -> :ok end"] do
        [guarded] = guarded_nodes(source)
        assert GuardDrop.validate(GuardDrop.mutate(guarded)) == :ok
      end
    end

    @tag :validate
    @tag spec: "mutagen.mutators.r11"
    test "skips a multi-parameter fn clause, whose guard mutate/1 cannot drop" do
      [guarded] = guarded_nodes("fn a, b when a > b -> a end")

      assert GuardDrop.mutate(guarded) == guarded
      assert GuardDrop.validate(GuardDrop.mutate(guarded)) == {:skip, :structurally_invalid}
    end
  end

  describe "enumeration" do
    @describetag spec: "mutagen.mutators.r11"

    test "covered guards become sites with the guard removed" do
      file = "lib/guarded_sample.ex"

      source = """
      defmodule GuardedSample do
        def only_positive(n) when is_integer(n) and n > 0, do: n
        def only_atoms(x) when is_atom(x), do: x

        def sign(x) do
          case x do
            n when n > 0 -> :positive
            _ -> :other
          end
        end

        def positive, do: fn x when x > 0 -> x end
        def pick, do: fn a, b when a > b -> a end
      end
      """

      result = enumerate(file, source, GuardedSample)
      sites = Enum.filter(result.sites, &(&1.mutator == :guard_drop))

      assert Enum.map(sites, &{&1.line, Macro.to_string(&1.mutated_ast)}) == [
               {2, "only_positive(n)"},
               {3, "only_atoms(x)"},
               {7, "n"},
               {12, "x"}
             ]

      for site <- sites do
        assert GuardDrop.validate(GuardDrop.mutate(site.original_ast)) == :ok
      end

      assert [%{reason: :structurally_invalid}] =
               Enum.filter(result.skipped, &(&1.mutator == :guard_drop))
    end

    test "the lane guarded fixture yields one site per guarded head and no skips" do
      file = "lib/lane_fixture/guarded.ex"
      source = File.read!(Path.join("test/fixtures/lane_project", file))

      result = enumerate(file, source, LaneFixture.Guarded)

      assert [{:only_positive, _, _}, {:only_atoms, _, _}] =
               result.sites
               |> Enum.filter(&(&1.mutator == :guard_drop))
               |> Enum.map(& &1.mutated_ast)

      refute Enum.any?(result.skipped, &(&1.mutator == :guard_drop))
    end
  end

  defp guarded_nodes(source) do
    source
    |> Code.string_to_quoted!()
    |> Macro.prewalk([], fn
      {:when, _, _} = node, acc -> {node, [node | acc]}
      node, acc -> {node, acc}
    end)
    |> elem(1)
    |> Enum.reverse()
  end

  defp enumerate(file, source, module) do
    {:ok, ast} = Code.string_to_quoted(source, columns: true, token_metadata: true, file: file)
    lines = source |> String.split("\n") |> length()
    scope = %Scope{file: file, line_range: 1..lines, module: module}

    MutationEnumerator.enumerate(%{file => {ast, source}}, [scope], %{
      file => MapSet.new(1..lines)
    })
  end
end
