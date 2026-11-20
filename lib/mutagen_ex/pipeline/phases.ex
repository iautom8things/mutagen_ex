defmodule MutagenEx.Pipeline.Phases do
  @moduledoc false

  alias MutagenEx.{Config, Runtime}
  alias MutagenEx.JsonReporter.Report

  @enforce_keys [:config, :dispatch, :output]
  defstruct [:config, :dispatch, :output, :host, :escalation_deadline]

  def scope(phases, report), do: phase_scope(phases.config, phases.dispatch, report)

  def tests(phases, report, paths),
    do: phase_tests(phases.config, phases.dispatch, report, paths)

  def ast_cache(phases, scopes, filter, report),
    do: phase_ast_cache(phases.config, scopes, filter, phases.dispatch, report)

  def coverage(phases, scopes, filter, modules, report) do
    time_phase(:coverage, report, phases.output.clock, fn ->
      phase_coverage(phases, scopes, filter, modules, report)
    end)
  end

  def enumerate(phases, ast, scopes, coverage, report),
    do: phase_enumerator(phases.config, ast, scopes, coverage, phases.dispatch, report)

  def test_input(phases, coverage, filter, report),
    do: phase_test_modules(phases.config, coverage, filter, report)

  def baseline(phases, input, report) do
    case time_phase(:baseline, report, phases.output.clock, fn ->
           phase_baseline(phases.config, input, phases.dispatch, report, phases.host)
         end) do
      {:ok, baseline, report} ->
        report = %{
          report
          | baseline: baseline_to_report(baseline),
            warnings: report.warnings ++ baseline.warnings
        }

        {:ok, baseline, report}

      abort ->
        abort
    end
  end

  def mutation(phases, plan, input, sites, budget, report) do
    config = %{phases.config | budget_ms: budget}
    report = put_mutant_deadline(report, config)

    time_phase(:mutation, report, phases.output.clock, fn ->
      phase_mutation(
        config,
        input,
        plan.cache,
        sites,
        plan.scopes,
        phases.dispatch,
        report,
        phases.output
      )
    end)
  end

  defp time_phase(phase, report, clock, run) do
    started_at = clock.(phase)

    case run.() do
      {:ok, result} ->
        {:ok, result, put_elapsed_timing(report, phase, clock.(phase) - started_at)}

      {:abort, partial, config, reason, details} ->
        {:abort, put_elapsed_timing(partial, phase, clock.(phase) - started_at), config, reason,
         details}
    end
  end

  def put_mutant_deadline(report, config) do
    baseline_ms = report.meta.timings_ms.baseline
    deadline = Config.mutant_deadline(config, baseline_ms)
    report = put_in(report.meta.timings_ms[:mutant_deadline], deadline)

    if deadline < baseline_ms do
      warning = {:mutant_deadline_below_baseline, deadline, baseline_ms}
      %{report | warnings: Enum.uniq(report.warnings ++ [warning])}
    else
      report
    end
  end

  defp put_elapsed_timing(%Report{meta: meta} = report, phase, elapsed) do
    elapsed_ms = System.convert_time_unit(elapsed, :native, :millisecond)
    %{report | meta: put_in(meta.timings_ms[phase], elapsed_ms)}
  end

  defp phase_scope(%Config{scopes: scopes} = config, dispatch, %Report{} = report) do
    mod = Map.fetch!(dispatch, :scope)

    result =
      Enum.reduce_while(scopes, {:ok, []}, fn target, {:ok, acc} ->
        case mod.resolve(target, []) do
          {:ok, records} ->
            {:cont, {:ok, [records | acc]}}

          {:error, reason, details} ->
            partial = %Report{report | scope: :lists.append(:lists.reverse(acc))}

            {:halt,
             {:abort, partial, config, reason,
              Map.merge(%{target: target, step: :scope}, details)}}
        end
      end)

    case result do
      {:ok, chunks_reversed} ->
        {:ok, :lists.append(:lists.reverse(chunks_reversed))}

      {:abort, _, _, _, _} = abort ->
        abort
    end
  end

  defp phase_tests(%Config{tests: tests} = config, dispatch, report, paths) do
    mod = Map.fetch!(dispatch, :tests)

    case mod.resolve(tests, test_paths: paths) do
      {:ok, filter} ->
        {:ok, filter}

      {:error, %{reason: reason} = details} ->
        {:abort, report, config, reason, Map.put_new(details, :step, :test_selection)}

      {:error, reason, details} when is_atom(reason) ->
        {:abort, report, config, reason, Map.put_new(details, :step, :test_selection)}
    end
  end

  # Cache the source and the selected test files together. Baseline uses
  # the cached test ASTs to detect async modules.
  defp phase_ast_cache(config, scope_records, test_filter, dispatch, report) do
    mod = Map.fetch!(dispatch, :ast_cache)

    scope_files = scope_records |> Enum.map(& &1.file) |> Enum.uniq()
    test_files = test_filter.files |> Enum.uniq()
    files = (scope_files ++ test_files) |> Enum.uniq()

    opts = [categories: %{scope: scope_files, test: test_files}]

    case mod.load(files, opts) do
      {:ok, cache} ->
        {:ok, cache}

      {:error, reason, details} ->
        {:abort, report, config, reason, Map.put_new(details, :step, :ast_cache)}
    end
  end

  defp phase_coverage(phases, scope_records, test_filter, modules, report) do
    mod = Map.fetch!(phases.dispatch, :coverage)

    in_scope_modules =
      scope_records
      |> Enum.map(&{&1.module, &1.file})
      |> Enum.uniq()

    input = %{
      seed: phases.config.seed,
      in_scope_modules: in_scope_modules,
      test_filter: test_filter
    }

    input = if modules == nil, do: input, else: Map.put(input, :test_modules, modules)

    case run_coverage(phases, fn -> mod.run(input) end) do
      {:ok, result} ->
        {:ok, result}

      {:error, reason, details} ->
        {:abort, report, phases.config, reason, Map.put_new(details, :step, :coverage)}
    end
  end

  # `--max-sites` flows in here so an over-budget enumeration aborts
  # before the runner even starts. The enumerator returns
  # `{:error, :too_many_sites, details}` when the produced sites would
  # exceed `Config.max_sites`; that becomes an abort-JSON document so
  # the user gets a structured "your scope is too large, narrow it"
  # signal rather than an OOM.
  defp phase_enumerator(
         %Config{max_sites: max_sites} = config,
         ast_cache,
         scope_records,
         coverage_result,
         dispatch,
         %Report{} = report
       ) do
    mod = Map.fetch!(dispatch, :enumerator)

    covered_lines = coverage_result.covered_lines

    case mod.enumerate(ast_cache, scope_records, covered_lines,
           max_sites: max_sites,
           coverable_lines: coverage_result[:coverable_lines],
           source: config.source
         ) do
      %{sites: _, skipped: _, warnings: _} = enum_result ->
        {:ok, enum_result}

      {:error, :too_many_sites, details} ->
        {:abort, report, config, :too_many_sites, Map.put_new(details, :step, :enumeration)}
    end
  end

  defp phase_test_modules(config, coverage, test_filter, report) do
    case MutagenEx.TestModuleDiscovery.for_tests(Map.put(coverage, :test_filter, test_filter)) do
      modules when is_list(modules) ->
        {:ok, %{test_filter: test_filter, test_modules: modules}}

      {:error, reason, details} ->
        {:abort, report, config, reason, details}
    end
  end

  defp phase_baseline(
         %Config{seed: seed} = config,
         test_input,
         dispatch,
         %Report{} = report,
         state
       ) do
    mod = Map.fetch!(dispatch, :baseline)

    input = Map.put(test_input, :seed, seed)

    baseline =
      case {input, state} do
        {%{escalation_timeout_ms: timeout}, _} ->
          Runtime.bounded_baseline(timeout, fn -> mod.run(input) end)

        {_, %{worker: _}} ->
          Runtime.bounded_baseline(suite_timeout(config), fn -> mod.run(input) end, :release)

        _ ->
          mod.run(input)
      end

    case baseline do
      {:ok, result} ->
        {:ok, result}

      {:error, :baseline_red, details} ->
        # r1: baseline failures populate `baseline` on the abort report.
        # The ExUnit counts feed the after-suite callbacks, not the document.
        {suite_stats, details} = Map.pop(details, :suite_stats)

        partial_baseline = %{
          "passed" => Map.get(details, :passed, 0),
          "failed" => Map.get(details, :failed, length(Map.get(details, :failures, []))),
          "failures" => Enum.map(Map.get(details, :failures, []), &failure_to_wire/1),
          suite_stats: suite_stats
        }

        partial = %Report{report | baseline: partial_baseline}

        {:abort, partial, config, :baseline_red, Map.put_new(details, :step, :baseline)}

      {:error, reason, details} ->
        {:abort, report, config, reason, Map.put_new(details, :step, :baseline)}
    end
  end

  defp run_coverage(%{host: %{worker: _}} = phases, fun) do
    timeout = suite_timeout(phases.config)

    timeout =
      case phases.escalation_deadline do
        nil -> timeout
        deadline -> min(timeout, max(0, deadline - System.monotonic_time(:millisecond)))
      end

    case MutagenEx.Test.RunGroup.with_deadline(timeout, fun, :release) do
      {:ok, result} ->
        result

      :timeout ->
        {:error, :coverage_timeout, %{phase: :coverage, limit: timeout}}

      {:exit, reason} ->
        {:error, :ex_unit_run_failed,
         %{phase: :coverage, message: "Suite worker exited: #{inspect(reason)}"}}
    end
  end

  defp run_coverage(_phases, fun), do: fun.()

  defp suite_timeout(config), do: max(config.boot_timeout_ms, 10 * config.timeout_ms)

  defp phase_mutation(
         %Config{seed: seed, budget_ms: budget_ms} = config,
         test_input,
         ast_cache,
         sites,
         scope_records,
         dispatch,
         report,
         %{stdout: stdout, progress: progress_reporter}
       ) do
    mod = Map.fetch!(dispatch, :mutation)

    site_sink = stream_sink(config, stdout)

    if config.stream do
      MutagenEx.JsonStreamer.emit_start(
        site_sink,
        length(sites),
        (report.meta || %{})
        |> Map.put_new(:tool_version, "0.0.0-dev")
      )
    end

    total = length(sites)

    stream_fn =
      if config.stream do
        fn
          {:result, result_map} ->
            MutagenEx.JsonStreamer.emit_result(
              site_sink,
              result_map,
              config
            )

          {:compile_error, entry} ->
            MutagenEx.JsonStreamer.emit_compile_error(site_sink, entry, config)
        end
      else
        fn _ -> :ok end
      end

    on_site_completed =
      fn payload ->
        stream_fn.(payload)
        if progress_reporter, do: progress_reporter.(payload, total)
        :ok
      end

    resolved_max_concurrency = config.max_concurrency || 1

    input =
      Map.merge(test_input, %{
        seed: seed,
        timeout_ms: report.meta.timings_ms.mutant_deadline,
        fail_fast: config.fail_fast,
        budget_ms: budget_ms,
        ast_cache: ast_cache,
        sites: sites,
        scope_records: scope_records,
        max_concurrency: resolved_max_concurrency,
        on_site_completed: on_site_completed
      })

    case mod.run(input) do
      {:ok, result} ->
        {:ok, result}

      {:error, reason, details} ->
        {warnings, details} = Map.pop(details, :host_warnings, [])

        {:abort, %{report | warnings: report.warnings ++ warnings}, config, reason,
         Map.put_new(details, :step, :mutation)}
    end
  end

  # The streaming sink resolves to the same destination as the final
  # aggregate document: stdout when `--json` is not set, otherwise the
  # canonicalised file path. The `--stream` mode appends per-site
  # lines AND the final aggregate document; consumers reading the
  # destination see N+2 JSON values (start, N per-site, end) followed
  # by one aggregate doc. The dispatch's `:io` key is the production
  # default's sink for the aggregate; the streamer writes incrementally
  # so we keep an open append handle for file outputs.
  def stream_sink(%Config{json_path: nil}, stdout), do: stdout

  def stream_sink(%Config{json_path: path}, _stdout) when is_binary(path) do
    # Use a process-local accumulator the IO step flushes at end-of-run.
    # Keeping a file open across the mutation phase introduces a leak
    # surface; building up iodata in the process dictionary is the
    # simplest, contention-free shape.
    fn iodata ->
      acc = Process.get(:mutagen_stream_buffer, [])
      Process.put(:mutagen_stream_buffer, [acc, iodata])
    end
  end

  def report_tests(%MutagenEx.TestSelector.TestFilter{} = f) do
    %{
      include: MutagenEx.TestSelector.report_filters(f, :include),
      exclude: MutagenEx.TestSelector.report_filters(f, :exclude),
      files: f.files
    }
  end

  def report_tests(other), do: other

  def report_coverage(%{covered_lines: covered} = result) do
    %{covered_lines: covered, suite_stats: result[:suite_stats]}
  end

  defp baseline_to_report(%{passed: p, failed: f, failures: fails} = result) do
    %{passed: p, failed: f, failures: fails, suite_stats: result[:suite_stats]}
  end

  # Per `mutagen.json_schema.r3`:
  #   total      = killed + survived + timeout + error  (all completed
  #                non-compile-error sites)
  #   completed  = same set
  #   kill_rate  = killed / (total - compile_error) when denominator > 0
  #
  # In v1 we model `total` as the count of non-skipped, non-compile-error
  # sites the runner attempted — exactly the four classifying outcomes.
  def report_mutation(mutation_result, enum_result) do
    results = mutation_result.results
    compile_errors = mutation_result.compile_errors

    {killed, survived, timeout, errored} =
      Enum.reduce(results, {0, 0, 0, 0}, fn r, {k, s, t, e} ->
        case r.status do
          :killed -> {k + 1, s, t, e}
          :survived -> {k, s + 1, t, e}
          :timeout -> {k, s, t + 1, e}
          :error -> {k, s, t, e + 1}
        end
      end)

    completed = killed + survived + timeout + errored
    compile_error_count = length(compile_errors)
    total = completed

    kill_rate =
      cond do
        total == 0 -> nil
        true -> killed / total
      end

    %{
      total: total,
      planned_sites: length(enum_result.sites),
      completed: completed,
      killed: killed,
      survived: survived,
      timeout: timeout,
      compile_error: compile_error_count,
      kill_rate: kill_rate,
      results: results,
      skipped: enum_result.skipped,
      compile_errors: compile_errors,
      state_drift_warning: mutation_result.state_drift_warning
    }
  end

  def enumerator_warnings(%{warnings: ws}) when is_list(ws) do
    Enum.map(ws, fn
      {:no_mutation_candidates, mod} ->
        "no_mutation_candidates: #{inspect(mod)}"

      other ->
        inspect(other)
    end)
  end

  def enumerator_warnings(_), do: []

  defp failure_to_wire({module, name}),
    do: %{"module" => inspect(module), "name" => to_string(name)}

  defp failure_to_wire(%{module: module, name: name}),
    do: %{"module" => inspect(module), "name" => to_string(name)}
end
