defmodule MutagenEx.Mutators.IdStabilityTest do
  @moduledoc """
  Golden test for `mutagen.mutators.r3` / `r4`: site IDs are stable.

  Covers:

    * **Within a single run** — `Mutators.site_id/3` is deterministic: ten
      consecutive invocations on the same source produce byte-identical IDs.
    * **Across `mix format`** — formatting the source (extra whitespace, line
      breaks) does not change the hash, because positional metadata is
      stripped before hashing.
  """

  use ExUnit.Case, async: true

  alias MutagenEx.Mutators

  @sample_source """
  defmodule Sample do
    def f(x), do: x + 1
    def g(x), do: x * 2
  end
  """

  @reformatted_source """
  defmodule Sample do
    def f(x),
      do: x + 1


    def g(x),
        do: x  *  2
  end
  """

  defp arith_nodes(source) do
    {:ok, ast} = Code.string_to_quoted(source)

    {_, acc} =
      Macro.prewalk(ast, [], fn
        {op, _, [_, _]} = node, acc when op in [:+, :-, :*, :/] ->
          {node, [node | acc]}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(acc)
  end

  test "site_id/3 is byte-identical across 10 consecutive invocations" do
    {:ok, ast} = Code.string_to_quoted("x + 1")
    ids = for _ <- 1..10, do: Mutators.site_id("lib/sample.ex", ast, :arith)

    assert length(ids) == 10
    assert Enum.uniq(ids) |> length() == 1, "IDs drifted: #{inspect(ids)}"
  end

  test "site_id/3 produces matching IDs across 10 invocations for every node in a real-ish source" do
    nodes = arith_nodes(@sample_source)
    assert length(nodes) == 2

    for node <- nodes do
      ids = for _ <- 1..10, do: Mutators.site_id("lib/sample.ex", node, :arith)
      assert ids |> Enum.uniq() |> length() == 1
    end
  end

  test "ID set is invariant under `mix format`-style reformatting (mutagen.mutators.r4)" do
    original_nodes = arith_nodes(@sample_source)
    reformatted_nodes = arith_nodes(@reformatted_source)

    assert length(original_nodes) == length(reformatted_nodes)

    original_ids =
      original_nodes
      |> Enum.map(&Mutators.site_id("lib/sample.ex", &1, :arith))
      |> MapSet.new()

    reformatted_ids =
      reformatted_nodes
      |> Enum.map(&Mutators.site_id("lib/sample.ex", &1, :arith))
      |> MapSet.new()

    assert MapSet.equal?(original_ids, reformatted_ids),
           """
           ID set changed across reformatting.
           original:    #{inspect(MapSet.to_list(original_ids))}
           reformatted: #{inspect(MapSet.to_list(reformatted_ids))}
           """
  end

  test "hash is preserved when only :line/:column/:end_line/:end_column differ" do
    a = {:+, [line: 5, column: 17, end_line: 5, end_column: 22], [{:x, [line: 5], nil}, 1]}
    b = {:+, [line: 99, column: 1, end_line: 99, end_column: 6], [{:x, [line: 99], nil}, 1]}

    assert Mutators.ast_hash(a) == Mutators.ast_hash(b)

    assert Mutators.site_id("lib/x.ex", a, :arith) == Mutators.site_id("lib/x.ex", b, :arith)
  end
end
