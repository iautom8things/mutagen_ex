#!/usr/bin/env elixir

# bench_ast_perf.exs — wrd25 AST/perf bench harness.
#
# Drives the real `Mix.Tasks.Mutagen.run/2` pipeline against the
# `wrd25_200sites` bench fixture, captures wall-clock, per-site time,
# `:erlang.memory/0` snapshots, and the SHA-256 of the emitted NDJSON
# document. Lets the operator dump a baseline JSON record and then,
# from a later commit, compare against it to score the speedup the
# `.25` refactor delivered.
#
# Usage:
#
#   # Plain run — prints wall-clock + memory + SHA-256, exits.
#   mix run priv/helper_scripts/bench_ast_perf.exs
#
#   # Capture run as a baseline (e.g. on the pre-.25 commit).
#   mix run priv/helper_scripts/bench_ast_perf.exs -- --baseline /tmp/bench_before.json
#
#   # Compare a fresh run against a prior baseline (e.g. on post-.25).
#   mix run priv/helper_scripts/bench_ast_perf.exs -- --compare /tmp/bench_before.json
#
#   # Capture and compare in one go (writes new baseline, prints delta).
#   mix run priv/helper_scripts/bench_ast_perf.exs -- \
#     --compare /tmp/bench_before.json \
#     --baseline /tmp/bench_after.json
#
#   # Override the per-run repetition count (default: 1):
#   mix run priv/helper_scripts/bench_ast_perf.exs -- --runs 2
#
# Notes:
#
#   * The harness is a `mix run` script — it runs *inside* the host
#     project's BEAM and reuses the loaded `MutagenEx` modules. No
#     subprocess, no separate compile.
#   * Output of the pipeline is captured via a process-message
#     `IoFacade` (same trick as `MutagenEx.DeterminismTest`), so the
#     NDJSON never hits disk — the SHA-256 hashes the in-memory iodata.
#   * The harness uses the same Baseline/Coverage collaborator fork as
#     `MutagenEx.EndToEndTest` (`Code.compile_file/1` on cited test
#     files before each phase) so the cited tests register with
#     ExUnit.Server before each phase's `ExUnit.run/0`.

defmodule Wrd25.BenchAstPerf do
  @moduledoc false

  @fixture_dir Path.expand("bench_fixtures/wrd25_200sites", __DIR__)
  @scope_target "lib/arith_dense.ex"
  @tests_target "test/arith_dense_test.exs"
  # Tight per-site budget keeps the bench bounded even on slow hosts.
  # The wrd25 fixture's arith_dense sites are simple; mutated runs that
  # survive into a real test timeout are uninteresting for perf scoring.
  @timeout_ms 2_000
  @max_total_ms 600_000

  defmodule CaptureIo do
    @moduledoc false
    @behaviour MutagenEx.Pipeline.IoFacade

    @impl MutagenEx.Pipeline.IoFacade
    def emit(iodata, exit_code, _config) do
      case Process.get(:bench_capture_target) do
        target when is_pid(target) ->
          ref = Process.get(:bench_capture_ref)
          send(target, {:bench_io, ref, iodata, exit_code})
          :ok

        _ ->
          IO.write(iodata)
      end
    end
  end

  defmodule BaselineFork do
    @moduledoc false
    @behaviour MutagenEx.Pipeline.BaselineFacade

    @impl MutagenEx.Pipeline.BaselineFacade
    def run(input) do
      Wrd25.BenchAstPerf.register_test_modules_for_phase!(input.test_filter.files)
      MutagenEx.Baseline.run(input)
    end
  end

  defmodule CoverageFork do
    @moduledoc false
    @behaviour MutagenEx.Pipeline.CoverageFacade

    @impl MutagenEx.Pipeline.CoverageFacade
    def run(input) do
      Wrd25.BenchAstPerf.register_test_modules_for_phase!(input.test_filter.files)
      MutagenEx.CoverageRunner.run(input)
    end
  end

  @doc false
  def register_test_modules_for_phase!(files) do
    Enum.each(files, fn file ->
      try do
        _ = Code.compile_file(file)
      rescue
        _ -> :ok
      catch
        _, _ -> :ok
      end
    end)

    :ok
  end

  def main(argv) do
    opts = parse_argv(argv)

    IO.puts("wrd25 bench — fixture: #{@fixture_dir}")

    unless File.dir?(@fixture_dir) do
      IO.puts(:stderr, "fixture dir does not exist: #{@fixture_dir}")
      System.halt(1)
    end

    # Force core MutagenEx modules to be loaded once before run #1 so
    # we measure steady-state code, not first-use compile time.
    _ = Code.ensure_loaded(Mix.Tasks.Mutagen)
    _ = Code.ensure_loaded(MutagenEx.MutationRunner)
    _ = Code.ensure_loaded(MutagenEx.MutationEnumerator)
    _ = Code.ensure_loaded(MutagenEx.AstCache)
    _ = Code.ensure_loaded(MutagenEx.ScopeResolver)

    # `mix run` does NOT start ExUnit. Without ExUnit.Server running,
    # `Code.require_file/1` on a `use ExUnit.Case` test file fails with
    # the `:test_file_load_failed` abort path because the
    # `__after_compile__` hook tries to call `ExUnit.Server.add_module/2`
    # against a process that doesn't exist. Start ExUnit here (with
    # `autorun: false` so the eventual VM shutdown doesn't trigger a
    # second suite run on top of the pipeline's nested `ExUnit.run/0`
    # calls).
    _ = Application.ensure_all_started(:ex_unit)
    _ = ExUnit.start(autorun: false)

    ensure_cover_loadable!()

    {compiled_modules, ebin} = compile_fixture!()

    try do
      runs =
        Enum.map(1..opts.runs, fn n ->
          reset_state!(compiled_modules)

          # Force a GC across all processes so memory-delta starts from
          # a well-defined baseline. Without this the noise floor is
          # large enough to swamp the signal.
          :erlang.garbage_collect()
          for p <- Process.list(), do: :erlang.garbage_collect(p)

          mem_before = memory_snapshot()
          procs_before = length(Process.list())

          IO.puts("\nrun #{n}/#{opts.runs}: starting …")

          {micros, captured} = :timer.tc(fn -> capture_pipeline_run!() end)

          mem_after = memory_snapshot()
          procs_after = length(Process.list())

          wall_ms = micros / 1_000.0
          per_site_us = if captured.sites > 0, do: micros / captured.sites, else: 0.0

          result = %{
            run: n,
            wall_ms: round2(wall_ms),
            per_site_us: round2(per_site_us),
            sites: captured.sites,
            sites_completed: captured.completed,
            ndjson_bytes: captured.bytes,
            ndjson_sha256: captured.sha256,
            exit_code: captured.exit_code,
            aborted: captured.aborted,
            abort_reason: captured.abort_reason,
            mem_total_kb_delta: round2((mem_after.total - mem_before.total) / 1024),
            mem_processes_kb_delta: round2((mem_after.processes - mem_before.processes) / 1024),
            mem_binary_kb_delta: round2((mem_after.binary - mem_before.binary) / 1024),
            mem_total_kb_peak: round2(mem_after.total / 1024),
            procs_delta: procs_after - procs_before
          }

          IO.puts(
            "  wall=#{result.wall_ms}ms  sites=#{result.sites}  " <>
              "completed=#{result.sites_completed}  " <>
              "per_site=#{result.per_site_us}µs  " <>
              "mem_total_Δ=#{result.mem_total_kb_delta}KB  " <>
              "aborted=#{result.aborted}  " <>
              "abort_reason=#{inspect(result.abort_reason)}  " <>
              "sha256=#{String.slice(result.ndjson_sha256, 0, 12)}…"
          )

          result
        end)

      summary = summarise(runs)
      print_summary(summary)

      if opts.baseline_path, do: write_baseline!(opts.baseline_path, summary, runs)
      if opts.compare_path, do: print_comparison(opts.compare_path, summary)

      :ok
    after
      cleanup_ebin!(ebin)
    end
  end

  # ---------------------------------------------------------------------------
  # Pipeline driver — mirrors `MutagenEx.DeterminismTest.run_capture!/1`
  # but adds the e2e-style Baseline/Coverage collaborators that register
  # cited test files via `Code.compile_file/1` before each phase.
  # ---------------------------------------------------------------------------

  defp capture_pipeline_run! do
    this = self()
    ref = make_ref()

    dispatch = %{
      io: CaptureIo,
      baseline: BaselineFork,
      coverage: CoverageFork
    }

    prior_cwd = File.cwd!()
    File.cd!(@fixture_dir)

    try do
      Process.put(:bench_capture_target, this)
      Process.put(:bench_capture_ref, ref)

      argv = [
        "--scope",
        @scope_target,
        "--tests",
        @tests_target,
        "--timeout-ms",
        Integer.to_string(@timeout_ms),
        "--seed",
        "0"
      ]

      try do
        Mix.Tasks.Mutagen.run(argv, dispatch)
      rescue
        e ->
          send(this, {:bench_raised, ref, Exception.message(e), __STACKTRACE__})
      catch
        kind, value ->
          send(this, {:bench_caught, ref, kind, value})
      end

      receive do
        {:bench_io, ^ref, iodata, exit_code} ->
          binary = IO.iodata_to_binary(iodata)

          # Drop a debug copy of the last captured JSON document so an
          # operator can inspect why a run aborted (the run-level
          # `abort_reason` field summarises the cause, but the full
          # document is useful for diagnostics).
          _ =
            try do
              File.write("/tmp/wrd25_bench_last.json", binary)
            rescue
              _ -> :ok
            end

          sha = :crypto.hash(:sha256, binary) |> Base.encode16(case: :lower)
          {total, completed, aborted, abort_reason} = parse_counts(binary)

          %{
            sha256: sha,
            sites: total,
            completed: completed,
            aborted: aborted,
            abort_reason: abort_reason,
            bytes: byte_size(binary),
            exit_code: exit_code
          }

        {:bench_raised, ^ref, message, _trace} ->
          raise "pipeline raised: " <> message

        {:bench_caught, ^ref, kind, value} ->
          raise "pipeline caught: #{inspect(kind)} #{inspect(value)}"
      after
        @max_total_ms ->
          raise "pipeline did not emit JSON within #{@max_total_ms}ms"
      end
    after
      File.cd!(prior_cwd)
      Process.delete(:bench_capture_target)
      Process.delete(:bench_capture_ref)
    end
  end

  # Extract the canonical site counts from the emitted JSON. Use regex
  # rather than a full JSON parse: keeps the harness dependency-free
  # (Jason is in the host project but not guaranteed across commits)
  # and we only care about three primitives.
  #
  # Shape (from `MutagenEx.JsonReporter`):
  #
  #     {
  #       "aborted": true|false,
  #       "mutation": {
  #         "total": N,
  #         "completed": M,
  #         ...
  #       }
  #     }
  defp parse_counts(binary) do
    total =
      case Regex.run(~r/"total"\s*:\s*(\d+)/, binary) do
        [_, n] -> String.to_integer(n)
        _ -> 0
      end

    completed =
      case Regex.run(~r/"completed"\s*:\s*(\d+)/, binary) do
        [_, n] -> String.to_integer(n)
        _ -> 0
      end

    aborted =
      case Regex.run(~r/"aborted"\s*:\s*(true|false)/, binary) do
        [_, "true"] -> true
        _ -> false
      end

    abort_reason =
      case Regex.run(~r/"abort_reason"\s*:\s*"([^"]*)"/, binary) do
        [_, reason] -> reason
        _ -> nil
      end

    {total, completed, aborted, abort_reason}
  end

  # ---------------------------------------------------------------------------
  # Memory accounting
  # ---------------------------------------------------------------------------

  defp memory_snapshot do
    mem = :erlang.memory()

    %{
      total: Keyword.fetch!(mem, :total),
      processes: Keyword.fetch!(mem, :processes),
      binary: Keyword.fetch!(mem, :binary)
    }
  end

  # ---------------------------------------------------------------------------
  # Fixture compile + per-run state reset (same recipe as
  # EndToEndTest.compile_lane_fixture / reset_e2e_state).
  # ---------------------------------------------------------------------------

  defp compile_fixture! do
    # Use a STABLE (path-pinned) tmp ebin so the path string embedded
    # in "module redefined" warnings the runner records in
    # `result.warnings[]` is identical across invocations. Without this
    # the per-invocation unique suffix would defeat the cross-commit
    # byte-identity SHA-256 the bench is supposed to record.
    ebin = Path.join(System.tmp_dir!(), "mutagen_ex_bench_stable_ebin")

    # Wipe-and-recreate so a stale previous run's beams from a
    # *different* commit don't get reloaded.
    _ = File.rm_rf!(ebin)
    File.mkdir_p!(ebin)
    Code.append_path(ebin)

    prior_opts = Code.compiler_options()
    Code.compiler_options(debug_info: true)

    lib_dir = Path.join(@fixture_dir, "lib")
    target_files = ["arith_dense.ex"]

    compiled =
      Enum.flat_map(target_files, fn f ->
        path = Path.join(lib_dir, f)
        Code.compile_file(path)
      end)

    for {mod, bin} <- compiled do
      File.write!(Path.join(ebin, "#{mod}.beam"), bin)
    end

    for {mod, _bin} <- compiled do
      :code.purge(mod)
      :code.delete(mod)

      case :code.load_file(mod) do
        {:module, ^mod} ->
          :ok

        other ->
          Code.compiler_options(prior_opts)
          File.rm_rf!(ebin)
          raise "could not reload #{inspect(mod)} from disk: #{inspect(other)}"
      end
    end

    Code.compiler_options(prior_opts)

    {Enum.map(compiled, fn {mod, _bin} -> mod end), ebin}
  end

  defp reset_state!(modules) do
    try do
      apply(:cover, :stop, [])
    rescue
      _ -> :ok
    catch
      _, _ -> :ok
    end

    Enum.each(modules, fn mod ->
      _ = :code.purge(mod)
      _ = :code.delete(mod)
      _ = :code.load_file(mod)
    end)

    Process.delete(:bench_capture_target)
    Process.delete(:bench_capture_ref)

    :ok
  end

  defp cleanup_ebin!(ebin) do
    Code.delete_path(ebin)

    try do
      File.rm_rf!(ebin)
    rescue
      _ -> :ok
    end
  end

  defp ensure_cover_loadable! do
    case Code.ensure_loaded(:cover) do
      {:module, :cover} ->
        :ok

      _ ->
        root = List.to_string(:code.root_dir())

        case Path.wildcard(Path.join(root, "lib/tools-*/ebin")) do
          [path | _] ->
            Code.append_path(path)
            {:module, :cover} = Code.ensure_loaded(:cover)
            :ok

          [] ->
            IO.puts(:stderr, "could not locate OTP tools-*/ebin under #{root}")
            System.halt(1)
        end
    end
  end

  # ---------------------------------------------------------------------------
  # Summary + comparison
  # ---------------------------------------------------------------------------

  defp summarise(runs) do
    walls = Enum.map(runs, & &1.wall_ms)
    per_sites = Enum.map(runs, & &1.per_site_us)
    sites_list = Enum.map(runs, & &1.sites)
    sha_set = runs |> Enum.map(& &1.ndjson_sha256) |> Enum.uniq()

    %{
      runs: length(runs),
      sites: List.first(sites_list),
      sites_consistent_across_runs: length(Enum.uniq(sites_list)) == 1,
      wall_ms_min: Enum.min(walls),
      wall_ms_max: Enum.max(walls),
      wall_ms_avg: round2(avg(walls)),
      per_site_us_min: Enum.min(per_sites),
      per_site_us_max: Enum.max(per_sites),
      per_site_us_avg: round2(avg(per_sites)),
      mem_total_kb_peak: Enum.map(runs, & &1.mem_total_kb_peak) |> Enum.max(),
      ndjson_sha256: List.first(sha_set),
      ndjson_byte_identical_across_runs: length(sha_set) == 1,
      ndjson_sha256s: sha_set,
      aborted_any: Enum.any?(runs, & &1.aborted),
      elixir: System.version(),
      otp: System.otp_release(),
      timestamp_utc: DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

  defp print_summary(s) do
    IO.puts("\nsummary (n=#{s.runs} run#{if s.runs == 1, do: "", else: "s"}):")
    IO.puts("  sites/run         : #{s.sites} (consistent: #{s.sites_consistent_across_runs})")

    IO.puts(
      "  wall_ms           : min=#{s.wall_ms_min}  max=#{s.wall_ms_max}  avg=#{s.wall_ms_avg}"
    )

    IO.puts(
      "  per_site_us       : min=#{s.per_site_us_min}  max=#{s.per_site_us_max}  avg=#{s.per_site_us_avg}"
    )

    IO.puts("  mem_total_kb_peak : #{s.mem_total_kb_peak}")
    IO.puts("  ndjson_sha256     : #{s.ndjson_sha256}")
    IO.puts("  byte-identical    : #{s.ndjson_byte_identical_across_runs}")
    IO.puts("  aborted_any       : #{s.aborted_any}")
    IO.puts("  elixir / otp      : #{s.elixir} / #{s.otp}")
  end

  defp write_baseline!(path, summary, runs) do
    payload = %{summary: summary, runs: runs}
    File.write!(path, encode_json(payload))
    IO.puts("\nbaseline written → #{path}")
  end

  defp print_comparison(prior_path, current) do
    case File.read(prior_path) do
      {:ok, data} ->
        prior_summary = decode_summary!(data)

        speedup_wall =
          safe_ratio(prior_summary["wall_ms_avg"], current.wall_ms_avg)

        speedup_per_site =
          safe_ratio(prior_summary["per_site_us_avg"], current.per_site_us_avg)

        IO.puts("\ncomparison vs baseline #{prior_path}:")

        IO.puts(
          "  baseline wall_ms_avg=#{prior_summary["wall_ms_avg"]}  " <>
            "current=#{current.wall_ms_avg}  speedup×=#{round2(speedup_wall)}"
        )

        IO.puts(
          "  baseline per_site_us_avg=#{prior_summary["per_site_us_avg"]}  " <>
            "current=#{current.per_site_us_avg}  speedup×=#{round2(speedup_per_site)}"
        )

        IO.puts("  baseline ndjson_sha256: #{prior_summary["ndjson_sha256"]}")
        IO.puts("  current  ndjson_sha256: #{current.ndjson_sha256}")

        cond do
          speedup_wall >= 2.0 ->
            IO.puts("  >= 2× speedup (within `.25` epic's documented 2–4× target).")

          speedup_wall >= 1.0 ->
            IO.puts(
              "  < 2× speedup. Per the `.25` epic ticket NOTE, file a follow-up and capture in CHANGELOG."
            )

          true ->
            IO.puts("  WARNING: regression (speedup < 1×).")
        end

      {:error, reason} ->
        IO.puts(:stderr, "could not read baseline #{prior_path}: #{inspect(reason)}")
    end
  end

  # ---------------------------------------------------------------------------
  # Tiny JSON encoder — dependency-free so baseline files written from
  # one commit can be read from a different commit without requiring
  # Jason / OTP json on either end. Same goes for `decode_summary!/1`.
  # ---------------------------------------------------------------------------

  defp encode_json(value), do: encode_value(value)

  defp encode_value(nil), do: "null"
  defp encode_value(b) when is_boolean(b), do: to_string(b)
  defp encode_value(n) when is_integer(n), do: Integer.to_string(n)
  defp encode_value(n) when is_float(n), do: Float.to_string(n)
  defp encode_value(s) when is_binary(s), do: "\"" <> escape_string(s) <> "\""
  defp encode_value(a) when is_atom(a), do: "\"" <> escape_string(Atom.to_string(a)) <> "\""

  defp encode_value(list) when is_list(list) do
    "[" <> Enum.map_join(list, ",", &encode_value/1) <> "]"
  end

  defp encode_value(%{} = m) do
    inner =
      m
      |> Enum.map(fn {k, v} ->
        key = if is_atom(k), do: Atom.to_string(k), else: to_string(k)
        "\"" <> escape_string(key) <> "\":" <> encode_value(v)
      end)
      |> Enum.join(",")

    "{" <> inner <> "}"
  end

  defp escape_string(s) do
    s
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
    |> String.replace("\n", "\\n")
    |> String.replace("\r", "\\r")
    |> String.replace("\t", "\\t")
  end

  # The baseline file is only ever produced by *this* script, so we know
  # the exact shape. Only the top-level summary's primitives are needed
  # for comparison; a regex extract is sufficient.
  defp decode_summary!(data) do
    summary_section =
      case Regex.run(~r/"summary"\s*:\s*\{((?:[^{}]|\{[^}]*\})*)\}/, data) do
        [_, inner] -> inner
        _ -> raise "baseline JSON missing summary section"
      end

    extract = fn key, kind ->
      pat =
        case kind do
          :num -> ~r/"#{key}"\s*:\s*([-0-9.eE+]+)/
          :str -> ~r/"#{key}"\s*:\s*"([^"]*)"/
        end

      case Regex.run(pat, summary_section) do
        [_, val] ->
          case kind do
            :num ->
              case Float.parse(val) do
                {f, _} -> f
                :error -> 0.0
              end

            :str ->
              val
          end

        _ ->
          nil
      end
    end

    %{
      "wall_ms_avg" => extract.("wall_ms_avg", :num),
      "per_site_us_avg" => extract.("per_site_us_avg", :num),
      "ndjson_sha256" => extract.("ndjson_sha256", :str)
    }
  end

  defp safe_ratio(_prior, current) when current in [nil, 0, 0.0], do: 0.0
  defp safe_ratio(nil, _current), do: 0.0
  defp safe_ratio(prior, current), do: prior / current

  # ---------------------------------------------------------------------------
  # Argument parsing
  # ---------------------------------------------------------------------------

  defp parse_argv(argv) do
    {opts, _, _} =
      OptionParser.parse(argv,
        strict: [baseline: :string, compare: :string, runs: :integer],
        aliases: [b: :baseline, c: :compare, n: :runs]
      )

    %{
      baseline_path: Keyword.get(opts, :baseline),
      compare_path: Keyword.get(opts, :compare),
      runs: Keyword.get(opts, :runs, 1)
    }
  end

  # ---------------------------------------------------------------------------
  # Misc helpers
  # ---------------------------------------------------------------------------

  defp avg([]), do: 0.0
  defp avg(xs), do: Enum.sum(xs) / length(xs)

  defp round2(n) when is_float(n), do: Float.round(n, 2)
  defp round2(n) when is_integer(n), do: n * 1.0
  defp round2(_), do: 0.0
end

Wrd25.BenchAstPerf.main(System.argv())
