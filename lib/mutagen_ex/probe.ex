defmodule MutagenEx.Probe do
  @moduledoc false

  alias MutagenEx.MutationRunner

  @key {__MODULE__, :active}
  @definitions [:def, :defp]
  @blocks [:if, :unless, :case, :cond, :with, :try, :receive, :for]
  @patterns [:=, :<-, :\\, :match?, :destructure]
  @syntax [:quote, :<<>>, :__aliases__, :when, :"::", :&]

  def hit({generation, index}) do
    case :persistent_term.get(@key, nil) do
      {^generation, counters} -> :atomics.put(counters, index, 1)
      _ -> :ok
    end
  end

  def run([], _plan, _suite), do: {:ok, %{evidence: %{}, baseline_ms: nil}}

  def run(sites, plan, suite) do
    generation = System.unique_integer([:positive])
    counters = :atomics.new(length(sites), signed: false)

    files =
      sites
      |> Enum.with_index(1)
      |> Enum.group_by(fn {site, _index} -> site.file end)
      |> Enum.sort()
      |> Enum.flat_map(fn {file, indexed} ->
        with {ast, _source} <- plan.cache[file],
             {probed, [_ | _] = placed} <- instrument(ast, indexed, generation) do
          [{file, ast, probed, placed}]
        else
          _ -> []
        end
      end)

    with {:ok, loaded, result} <-
           MutationRunner.with_probe_files(files, fn ->
             count_hits(generation, counters, suite)
           end) do
      results = Map.new(sites, &{&1.id, {:could_not_tell, :probe_unwrappable}})

      evidence =
        Enum.reduce(files, results, fn {file, _, _, placed}, acc ->
          Enum.reduce(placed, acc, fn {id, index}, rows ->
            Map.put(rows, id, outcome(file, index, loaded, result, counters))
          end)
        end)

      baseline_ms =
        case result do
          {:ok, milliseconds} -> milliseconds
          _ -> nil
        end

      {:ok, %{evidence: evidence, baseline_ms: baseline_ms}}
    end
  end

  defp count_hits(generation, counters, suite) do
    :persistent_term.put(@key, {generation, counters})

    try do
      suite.()
    after
      :persistent_term.erase(@key)
    end
  end

  defp outcome(file, index, loaded, result, counters) do
    cond do
      not MapSet.member?(loaded, file) -> {:could_not_tell, :probe_compile_failed}
      not match?({:ok, _}, result) -> {:could_not_tell, :probe_suite_failed}
      :atomics.get(counters, index) == 1 -> {:probe, :executed}
      true -> {:probe, :uncovered}
    end
  end

  def pending(site, {execution, result}) do
    row =
      Map.take(site, [
        :id,
        :file,
        :line,
        :column,
        :mutator,
        :function,
        :definition_line,
        :in_scope,
        :original_ast,
        :mutated_ast
      ])
      |> Map.put(:execution, execution)

    case {execution, result} do
      {:probe, :executed} ->
        Map.put(row, :reason, :not_run)

      {:probe, :uncovered} ->
        Map.put(row, :reason, :uncovered)

      {:could_not_tell, reason} ->
        Map.merge(row, %{reason: :could_not_tell, probe_reason: reason})
    end
  end

  def instrument(ast, indexed, generation) do
    placements =
      for {site, index} <- indexed,
          {:ok, path} <- [placement(ast, site.path, :outside, [])],
          do: {path, {site.id, index}}

    probed =
      placements
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
      |> Enum.sort_by(fn {path, _} -> {-length(path), path} end)
      |> Enum.reduce(ast, fn {path, entries}, current ->
        {:ok, updated} =
          MutationRunner.rewrite_at_path(current, path, fn node ->
            hits =
              Enum.map(entries, fn {_id, index} ->
                {{:., [], [__MODULE__, :hit]}, [generated: true], [{generation, index}]}
              end)

            {:ok, {:__block__, [generated: true], hits ++ [node]}}
          end)

        updated
      end)

    {probed, Enum.map(placements, &elem(&1, 1))}
  end

  defp placement({kind, _, _}, _rest, _mode, _path) when kind in @syntax, do: :error

  defp placement({kind, _, [_, keywords]}, [{:arg, 1} | rest], _mode, path)
       when kind in @definitions do
    keyword_body(keywords, rest, [{:arg, 1} | path])
  end

  defp placement({kind, _, _}, _rest, _mode, _path) when kind in @definitions, do: :error

  defp placement({:->, _, [_, body]}, [{:arg, 1} | rest], :expression, path),
    do: placement(body, rest, :expression, [{:arg, 1} | path])

  defp placement({:->, _, _}, _rest, _mode, _path), do: :error

  defp placement({kind, _, _}, [{:arg, 0} | _], :expression, _path)
       when kind in @patterns,
       do: :error

  defp placement(_node, [], :expression, path), do: {:ok, Enum.reverse(path)}

  defp placement({kind, _, args}, [{:arg, index} = step | rest], :expression, path)
       when kind in @blocks and is_list(args) do
    arg = Enum.at(args, index)

    if Keyword.keyword?(arg),
      do: keyword_body(arg, rest, [step | path]),
      else: placement(arg, rest, :expression, [step | path])
  end

  defp placement({kind, _, args}, [{:arg, index} = step | rest], mode, path)
       when is_list(args) do
    arg = Enum.at(args, index)

    if mode == :expression and kind != :__block__ and Keyword.keyword?(arg) do
      :error
    else
      placement(arg, rest, mode, [step | path])
    end
  end

  defp placement({left, _}, [:left | rest], mode, path),
    do: placement(left, rest, mode, [:left | path])

  defp placement({_, right}, [:right | rest], mode, path),
    do: placement(right, rest, mode, [:right | path])

  defp placement(list, [{:elem, index} = step | rest], mode, path) when is_list(list) do
    case {mode, Keyword.keyword?(list), rest} do
      {:expression, true, []} -> {:ok, Enum.reverse(path)}
      {:expression, true, [:left | _]} -> :error
      _ -> placement(Enum.at(list, index), rest, mode, [step | path])
    end
  end

  defp placement(_node, _rest, _mode, _path), do: :error

  defp keyword_body(keywords, [{:elem, index} = step, :right | rest], path) do
    case Enum.at(keywords, index) do
      {key, body} when key in [:do, :else, :after, :rescue, :catch] ->
        placement(body, rest, :expression, [:right, step | path])

      _ ->
        :error
    end
  end

  defp keyword_body(_keywords, _rest, _path), do: :error
end
