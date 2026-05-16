#!/usr/bin/env elixir

# bench_ast_perf.exs — S1 skeleton, S6 completes the harness.
#
# Runs the `wrd25_200sites` bench fixture twice and reports wall-clock
# and memory deltas. The intent is to give the `.25` epic a single
# scriptable lever for measuring before/after the AST-cache / batched-
# prewalk / cached-beam-restore work.
#
# Status: SKELETON. The double-run loop, timing capture, and report
# shape are wired here. S6 fills in:
#
#   * driving the bench through the real `Mix.Tasks.Mutagen` pipeline
#     (the current skeleton only locates and counts files);
#   * the actual memory accounting via `:erlang.memory/0` snapshots
#     around each run (currently a placeholder so S6 can swap it in
#     without re-litigating the surrounding script shape);
#   * a `--baseline <path>` / `--compare <path>` flag set so the bench
#     can emit a structured before/after JSON diff for PR comments.
#
# Run with:
#
#     mix run priv/helper_scripts/bench_ast_perf.exs
#
# (Requires running from the mutagen_ex repo root so the fixture path
# resolves correctly.)

defmodule Wrd25.BenchAstPerf do
  @moduledoc false

  @fixture_dir Path.expand("bench_fixtures/wrd25_200sites", __DIR__)
  @runs 2

  def main(_args \\ []) do
    IO.puts("wrd25_200sites bench — skeleton (S1, completed in S6)")
    IO.puts("fixture dir: #{@fixture_dir}")

    if not File.dir?(@fixture_dir) do
      IO.puts(:stderr, "fixture dir does not exist: #{@fixture_dir}")
      System.halt(1)
    end

    {lib_files, test_files} = enumerate_fixture()

    IO.puts("lib files:  #{length(lib_files)}")
    IO.puts("test files: #{length(test_files)}")
    IO.puts("")

    results =
      Enum.map(1..@runs, fn n ->
        IO.write("run #{n}/#{@runs}: ")

        before_mem = total_memory()

        {micros, _result} =
          :timer.tc(fn ->
            # S6 placeholder: drive the actual pipeline here. For S1 the
            # bench just walks the fixture's ASTs to exercise the file-
            # read + parse path that the helper-lift refactor touched.
            parse_pass(lib_files)
          end)

        after_mem = total_memory()
        wall_ms = micros / 1_000.0
        mem_delta_kb = (after_mem - before_mem) / 1024.0

        IO.puts("wall=#{Float.round(wall_ms, 2)}ms  mem_delta=#{Float.round(mem_delta_kb, 2)}KB")

        %{run: n, wall_ms: wall_ms, mem_delta_kb: mem_delta_kb}
      end)

    IO.puts("")
    summary(results)
  end

  defp enumerate_fixture do
    {
      Path.wildcard(Path.join(@fixture_dir, "lib/**/*.ex")) |> Enum.sort(),
      Path.wildcard(Path.join(@fixture_dir, "test/**/*.exs")) |> Enum.sort()
    }
  end

  # S1: a no-op proxy for the eventual pipeline call — parse each lib
  # file once. S6 swaps this for the full `Mix.Tasks.Mutagen.run/2`
  # invocation with bench-mode args.
  defp parse_pass(files) do
    Enum.map(files, fn file ->
      source = File.read!(file)
      {:ok, _ast} = Code.string_to_quoted(source, columns: true, token_metadata: true)
      file
    end)
  end

  defp total_memory do
    Keyword.fetch!(:erlang.memory(), :total)
  end

  defp summary(results) do
    walls = Enum.map(results, & &1.wall_ms)
    mems = Enum.map(results, & &1.mem_delta_kb)

    IO.puts("summary:")
    IO.puts("  wall_ms      : min=#{fmt(Enum.min(walls))}  max=#{fmt(Enum.max(walls))}  avg=#{fmt(avg(walls))}")
    IO.puts("  mem_delta_kb : min=#{fmt(Enum.min(mems))}  max=#{fmt(Enum.max(mems))}  avg=#{fmt(avg(mems))}")
    IO.puts("")
    IO.puts("(S6 turns this into a structured before/after comparison.)")
  end

  defp avg([]), do: 0.0
  defp avg(xs), do: Enum.sum(xs) / length(xs)

  defp fmt(n) when is_float(n), do: Float.round(n, 2)
  defp fmt(n), do: n
end

Wrd25.BenchAstPerf.main(System.argv())
