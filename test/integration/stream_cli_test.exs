defmodule MutagenEx.Integration.StreamCliTest do
  @moduledoc """
  CLI-level `mix mutagen --stream` integration test (mutagen-hcs.8).

  Closes the coverage gap that hid the `--stream` ship-blocker: before this
  test, `test/mutagen_ex/json_streamer_test.exs` only exercised
  `MutagenEx.JsonStreamer.emit_start/3` (and friends) directly with a
  hand-built plain map. The real Mix-task `--stream` path — which fed the
  streamer `report.meta` through `Map.from_struct/1`, raising a
  `FunctionClauseError` on the plain meta map before a single NDJSON line was
  written — had ZERO integration coverage and so the crash shipped green.

  This test boots a brand-new Mix project in `System.tmp_dir!()`, wires
  `mutagen_ex` as a `path:` dep, writes a trivial scope + test, and drives
  `mix mutagen --stream` via `System.cmd/3` from a fresh shell — the same
  bootstrap as `MutagenEx.Integration.DownstreamAdoptionTest`. It asserts:

    * the run exits `0` (no `FunctionClauseError`);
    * stdout is well-formed line-delimited JSON: a `start` envelope, one or
      more per-site `result` / `compile_error` lines, then an `end` envelope,
      each carrying the documented `kind` discriminator
      (`mutagen.json_schema.r14`), followed by the aggregate document
      without a `kind` field; and
    * `--stream`'s NDJSON lands on the json sink (stdout here) and does NOT
      leak onto stderr — stdout is the contract surface, stderr is reserved
      for the progress feed, so the `.7` progress/stream composition (two
      independent sinks) is not regressed. Progress's own `:auto`
      TTY-gating is covered by the in-process `__build_progress_reporter__`
      unit tests; here stderr is a pipe (no TTY) so no progress is emitted,
      and the assertion is that the NDJSON stream stays off stderr.

  Tagged `:stream_integration` (its own tag, matching the per-suite tagging
  convention in `DownstreamAdoptionTest`) so the default `mix test` run skips
  it: it spawns an OS child process and is far slower than the in-process
  suite. Run explicitly via `mix test --include stream_integration` or
  `mix test.integration`.
  """

  use ExUnit.Case, async: false

  @moduletag :stream_integration

  # `__DIR__` is `test/integration/`; climb two segments to the repo root so
  # the generated downstream project can point a `path:` dep back at us.
  @project_root Path.expand("../..", __DIR__)

  @tag spec: [
         "mutagen.json_schema.r14",
         "mutagen.json_schema.r25",
         "mutagen.json_schema.r30",
         "mutagen.mutation_pipeline.r25"
       ]
  test "`mix mutagen --stream` emits valid NDJSON and exits 0" do
    rand = :rand.uniform(1_000_000_000) |> Integer.to_string()
    app_name = "mutagen_ex_stream_test_#{rand}"
    tmp_dir = Path.join(System.tmp_dir!(), app_name)

    File.rm_rf!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    # ── 1. Bootstrap a fresh Mix project. ────────────────────────────────
    {new_out, new_code} =
      System.cmd("mix", ["new", app_name],
        cd: System.tmp_dir!(),
        stderr_to_stdout: true,
        env: clean_env()
      )

    assert new_code == 0, "`mix new #{app_name}` failed (exit #{new_code}):\n#{new_out}"

    # ── 2. Patch mix.exs to add mutagen_ex as a path: dep. ───────────────
    mix_exs_path = Path.join(tmp_dir, "mix.exs")
    original_mix_exs = File.read!(mix_exs_path)

    deps_block = """
    defp deps do
        [
          {:mutagen_ex, path: #{inspect(@project_root)}}
        ]
      end\
    """

    patched_mix_exs =
      Regex.replace(
        ~r/defp deps do\s*\[.*?\]\s*end/s,
        original_mix_exs,
        deps_block,
        global: false
      )

    assert patched_mix_exs != original_mix_exs,
           "failed to inject mutagen_ex path: dep into generated mix.exs:\n#{original_mix_exs}"

    File.write!(mix_exs_path, patched_mix_exs)

    # ── 3. Write a trivial scope module + test. ──────────────────────────
    calc_module = Macro.camelize(app_name) <> ".Calc"
    calc_path = Path.join([tmp_dir, "lib", app_name, "calc.ex"])
    File.mkdir_p!(Path.dirname(calc_path))

    File.write!(calc_path, """
    defmodule #{calc_module} do
      @moduledoc false

      def add(a, b), do: a + b + 0

      def check(x) do
        with :ok <- x, {:ok, x} <- x, do: {:passed, x}
      end
    end
    """)

    calc_test_path = Path.join([tmp_dir, "test", app_name, "calc_test.exs"])
    File.mkdir_p!(Path.dirname(calc_test_path))

    File.write!(calc_test_path, """
    defmodule #{calc_module}Test do
      use ExUnit.Case, async: true

      test "add/2 sums two integers" do
        assert #{calc_module}.add(1, 2) == #{calc_module}.Helper.expected()
      end

      test "add/2 is commutative for integers" do
        assert #{calc_module}.add(2, 3) == #{calc_module}.add(3, 2)
      end

      test "check/1 returns the failed first match" do
        assert #{calc_module}.check({:ok, :ok}) == {:ok, :ok}
      end
    end

    defmodule #{calc_module}ParameterizedTest do
      use ExUnit.Case, async: true, parameterize: [%{left: 1, right: 2}, %{left: 2, right: 3}]

      test "each registration receives its parameters", %{left: left, right: right} do
        # Give the measured baseline a duration above the millisecond resolution.
        Process.sleep(5)
        assert #{calc_module}.add(left, right) == left + right
      end
    end

    defmodule #{calc_module}.Helper do
      def expected, do: 3
    end
    """)

    # ── 4. Resolve deps once before driving `mix mutagen --stream`. ──────
    {deps_out, deps_code} =
      System.cmd("mix", ["deps.get"],
        cd: tmp_dir,
        stderr_to_stdout: true,
        env: clean_env()
      )

    assert deps_code == 0, "`mix deps.get` failed (exit #{deps_code}):\n#{deps_out}"

    # ── 5. Drive `mix mutagen --stream` and capture stdout (NDJSON) and
    #      stderr SEPARATELY so we can assert the NDJSON stream lands on
    #      stdout (the json sink) without leaking onto stderr. The child's
    #      stderr is a pipe, not a TTY, so progress's `:auto` gate stays
    #      off — what matters here is that the stream path no longer
    #      crashes and the two sinks stay distinct. ──────────────────────
    relative_scope = Path.join(["lib", app_name, "calc.ex"])
    relative_tests = Path.join(["test", app_name, "calc_test.exs"])

    stderr_path = Path.join(tmp_dir, "mutagen.stderr")

    port_args = [
      "mutagen",
      "--stream",
      "--scope",
      relative_scope,
      "--tests",
      relative_tests
    ]

    # `System.cmd/3` with `stderr_to_stdout: false` discards stderr, so
    # redirect it to a file via `sh -c` to capture progress separately.
    {mutagen_out, mutagen_code} =
      System.cmd(
        "sh",
        ["-c", shell_command(port_args, stderr_path)],
        cd: tmp_dir,
        env: clean_env()
      )

    assert mutagen_code == 0,
           """
           `mix mutagen --stream` exited #{mutagen_code} (expected 0 — a
           non-zero exit here is the FunctionClauseError this ticket fixes).
           stdout:
           #{mutagen_out}
           stderr:
           #{File.read(stderr_path) |> elem(1)}
           """

    {ndjson, [aggregate]} =
      mutagen_out
      |> json_lines()
      |> Enum.split(-1)

    refute Map.has_key?(aggregate, "kind")

    assert %{
             "baseline" => %{"passed" => 5, "failed" => 0},
             "mutation" => %{"results" => aggregate_results}
           } = aggregate

    kinds = Enum.map(ndjson, & &1["kind"])

    assert List.first(kinds) == "start",
           "expected the first NDJSON line to be a `start` envelope, got kinds: #{inspect(kinds)}"

    assert List.last(kinds) == "end",
           "expected the last NDJSON line to be an `end` envelope, got kinds: #{inspect(kinds)}"

    middle = kinds |> Enum.drop(1) |> Enum.drop(-1)

    assert middle != [],
           "expected at least one per-site `result`/`compile_error` line between " <>
             "start and end, got kinds: #{inspect(kinds)}"

    assert Enum.all?(middle, &(&1 in ["result", "compile_error"])),
           "per-site NDJSON lines must be `result` or `compile_error`, got: #{inspect(kinds)}"

    # Every NDJSON line carries the schema version literal — proves the
    # lines are the contract surface, not stray JSON-shaped stdout.
    assert Enum.all?(ndjson, &(&1["version"] == "2")),
           "every NDJSON line must carry version \"2\": #{inspect(ndjson)}"

    results = Enum.filter(ndjson, &(&1["kind"] == "result"))
    assert [_ | _] = arith_results = Enum.filter(results, &(&1["mutator"] == "arith"))
    assert Enum.all?(arith_results, &(&1["confidence"] == "high"))

    assert [%{"confidence" => "low", "status" => "killed"} = swap] =
             Enum.filter(results, &(&1["mutator"] == "with_swap"))

    assert [%{"confidence" => "low", "status" => "killed"}] =
             Enum.filter(aggregate_results, &(&1["id"] == swap["id"]))

    start_line = List.first(ndjson)
    assert start_line["meta"]["id_scheme"] == "2"

    assert swap["function"] == "#{calc_module}.check/1"

    for %{"kind" => "result"} = result <- ndjson do
      assert result["function"] in ["#{calc_module}.add/2", "#{calc_module}.check/1"]
    end

    assert Enum.all?(arith_results, &(&1["function"] == "#{calc_module}.add/2"))

    assert is_integer(start_line["total"]) and start_line["total"] > 0,
           "start envelope must carry a positive total: #{inspect(start_line)}"

    assert is_map(start_line["meta"]),
           "start envelope must carry a meta map (the bug crashed building this): " <>
             inspect(start_line)

    end_line = List.last(ndjson)

    assert %{"timings_ms" => timings} = aggregate["meta"]

    assert mutagen_out =~
             ~r/"timings_ms":\{"baseline":\d+,"boot":\d+,"coverage":\d+,"mutant_deadline":\d+,"mutation":\d+,"total":\d+\}/

    assert Map.keys(timings) |> Enum.sort() ==
             ~w(baseline boot coverage mutant_deadline mutation total)

    assert Enum.all?(timings, fn {_, ms} -> is_integer(ms) and ms >= 0 end)
    assert timings["boot"] > 0
    assert timings["coverage"] > 0
    assert timings["baseline"] > 0
    assert timings["mutation"] > 0
    assert timings["mutant_deadline"] == max(5_000, 5 * timings["baseline"])
    measured = Map.drop(timings, ["total", "mutant_deadline"])
    assert timings["total"] >= Enum.sum(Map.values(measured))
    assert Map.delete(aggregate["meta"], "timings_ms") == start_line["meta"]
    assert start_line["meta"] == end_line["meta"]
    refute Enum.any?(results, &Map.has_key?(&1, "meta"))

    assert end_line["aborted"] == false,
           "end envelope must report aborted: false on a clean run: #{inspect(end_line)}"

    # ── 7. Sink separation: the NDJSON stream lands on stdout (the json
    #      sink) and never leaks onto stderr — the `.7` two-sink
    #      composition is intact. ──────────────────────────────────────
    {:ok, stderr} = File.read(stderr_path)
    refute stderr =~ "UndefinedFunctionError"

    assert Enum.count(
             String.split(stderr, "\n"),
             &(&1 == "Use --json PATH for reliable reports in scripts and CI.")
           ) == 1

    refute Enum.any?(aggregate_results, fn result ->
             Enum.any?(result["warnings"], &String.contains?(&1, "__ex_unit__"))
           end)

    refute stream_emitted_on_stderr?(stderr),
           "NDJSON envelope lines must not leak onto stderr (json sink is stdout):\n#{stderr}"

    {abort_out, 2} =
      System.cmd(
        "sh",
        ["-c", shell_command(port_args ++ ["--max-sites", "1"], stderr_path)],
        cd: tmp_dir,
        env: clean_env()
      )

    assert [
             %{
               "kind" => "end",
               "aborted" => true,
               "abort_reason" => "too_many_sites",
               "version" => "2",
               "meta" => %{"id_scheme" => "2"}
             } = abort_end,
             %{
               "aborted" => true,
               "abort_reason" => "too_many_sites",
               "meta" => %{"timings_ms" => abort_timings}
             } = abort_aggregate
           ] =
             json_lines(abort_out)

    refute Map.has_key?(abort_aggregate, "kind")
    refute Map.has_key?(abort_end["meta"], "timings_ms")

    for report <- [abort_aggregate, abort_end] do
      assert %{"complete" => false, "incomplete_reasons" => [%{"reason" => "too_many_sites"}]} =
               report["meta"]
    end

    assert abort_timings["coverage"] > 0
    assert abort_timings["baseline"] == 0
    assert abort_timings["mutation"] == 0
  end

  defp json_lines(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.filter(&String.starts_with?(&1, "{"))
    |> Enum.map(&:json.decode/1)
  end

  # Build a `sh -c` command string that runs `mix <args>` with stderr
  # redirected to `stderr_path`, leaving stdout (the NDJSON sink) on the
  # captured pipe. Args are shell-escaped.
  defp shell_command(args, stderr_path) do
    escaped = args |> Enum.map(&shell_escape/1) |> Enum.join(" ")
    "mix #{escaped} 2> #{shell_escape(stderr_path)}"
  end

  defp shell_escape(arg), do: "'" <> String.replace(arg, "'", "'\\''") <> "'"

  # A stdout line is part of the NDJSON stream if it is a JSON object that
  # decodes and carries a `kind` discriminator. ExUnit failure output and
  # other stdout noise will not satisfy all three.
  defp stream_line?(line) do
    String.starts_with?(line, "{") and String.ends_with?(line, "}") and
      case safe_decode(line) do
        {:ok, %{"kind" => _}} -> true
        _ -> false
      end
  end

  defp stream_emitted_on_stderr?(stderr) do
    stderr
    |> String.split("\n", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.any?(&stream_line?/1)
  end

  defp safe_decode(line) do
    {:ok, :json.decode(line)}
  rescue
    _ -> :error
  end

  defp clean_env do
    [
      {"MIX_ENV", "test"},
      {"MIX_TARGET", nil}
    ]
  end
end
