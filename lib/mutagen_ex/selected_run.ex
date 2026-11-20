defmodule MutagenEx.SelectedRun do
  @moduledoc false

  alias MutagenEx.{AutoTests, ChangedScope, MutationEnumerator, TestModuleDiscovery}
  alias MutagenEx.Test.ExUnitServer

  @candidate_errors ~w(baseline_red baseline_timeout ex_unit_run_failed no_tests_run test_file_load_failed)a
  @coverage_errors ~w(coverage_timeout no_tests_run ex_unit_run_failed test_file_load_failed
                      cover_already_running cover_compile_failed cover_module_unavailable module_beam_missing)a

  def run(plan, report, config, filter, test_paths, phases) do
    state = %{
      report: report,
      filter: filter,
      selection: plan.selection,
      tried: MapSet.new(filter.files),
      files: filter.files,
      no_tests: nil,
      stopped: nil,
      rejected: %{},
      loads: %{},
      dropped_files: MapSet.new(),
      coverage: %{},
      results: %{},
      compile_errors: %{},
      dropped: [],
      drift: %{},
      escalation: [],
      mutation_ms: 0,
      truncated: false,
      tainted: false
    }

    with {:ok, narrow} <- narrow(plan, config, state, phases),
         {:ok, state} <- run_escalation(plan, config, narrow, test_paths, phases) do
      state =
        state
        |> put_in([:report, Access.key!(:meta), :timings_ms], %{
          narrow.report.meta.timings_ms
          | mutation: state.mutation_ms
        })
        |> put_in([:report, Access.key!(:baseline)], narrow.report.baseline)

      complete(plan, state)
    end
  end

  defp run_escalation(plan, config, state, paths, phases) do
    escalate(plan, config, state, paths, phases)
  rescue
    exception ->
      {:abort, state.report, config, :escalation_crashed,
       %{step: :escalation, exception: inspect(exception.__struct__)}}
  end

  defp narrow(%{sites: []}, _config, state, _phases), do: {:ok, state}

  defp narrow(_plan, _config, %{filter: %{files: []}} = state, _phases) do
    {:ok, %{state | no_tests: "no_tests_run"}}
  end

  defp narrow(plan, config, state, {mod, phases} = execution) do
    case mod.coverage(phases, plan[:scopes], state.filter, nil, state.report) do
      {:ok, coverage, report} ->
        state = %{state | report: report, coverage: coverage.covered_lines}

        with {:ok, input} <- mod.test_input(phases, coverage, state.filter, report),
             {:ok, _baseline, report} <- mod.baseline(phases, input, report) do
          sites = Enum.filter(plan.sites, &MutationEnumerator.covered?(&1, state.coverage))
          mutate(:narrow, plan, sites, config, %{state | report: report}, input, execution)
        end

      {:abort, report, _, :no_tests_run, details} ->
        warning =
          "no_tests_run: coverage excluded #{details[:excluded] || 0}, skipped #{details[:skipped] || 0}"

        {:ok, %{state | report: report, no_tests: warning}}

      abort ->
        abort
    end
  end

  defp escalate(plan, %{tests: ["auto"], escalate: true} = config, state, test_paths, phases) do
    timeout = candidate_timeout(config, state.report.meta.timings_ms[:baseline] || 0)

    Enum.reduce_while([:module, :function], {:ok, state}, fn stage, {:ok, current} ->
      candidates = remaining_sites(plan, current)

      if candidates == [] or current.truncated do
        {:halt, {:ok, current}}
      else
        case escalate_stage(stage, candidates, plan, config, current, test_paths, timeout, phases) do
          {:ok, next} -> {:cont, {:ok, next}}
          {:stop, next} -> {:halt, {:ok, next}}
          {:abort, _, _, _, _} = abort -> {:halt, abort}
        end
      end
    end)
  end

  defp escalate(_plan, _config, state, _test_paths, _phases), do: {:ok, state}

  defp escalate_stage(stage, candidates, plan, config, state, test_paths, timeout, phases) do
    started = System.monotonic_time(:millisecond)
    survivors_in = length(survivors(state))
    dropped_in = MapSet.size(state.dropped_files)
    state = update_in(state.report.meta.timings_ms, &Map.delete(&1, :mutant_deadline))

    {files, capped?, unreadable} =
      AutoTests.discover(stage, candidates, test_paths, state.tried, config.escalate_max_files)

    state = Enum.reduce(unreadable, state, &reject(&2, &1, :test_read_failed))

    with {:ok, admitted, state} <- admit(files, timeout, state, phases),
         {:ok, state, added} <- run_stage(stage, admitted, plan, config, timeout, state, phases) do
      step = %{
        step: stage,
        files_added: added,
        capped: capped?,
        survivors_in: survivors_in,
        survivors_out: length(survivors(state)),
        dropped_after_load: MapSet.size(state.dropped_files) - dropped_in,
        candidate_deadline_ms: if(files != [], do: timeout),
        wall_ms: elapsed(started),
        baseline:
          if(added != [],
            do: Map.take(state.report.baseline || %{}, [:passed, :failed, :failures])
          ),
        baseline_ms: if(added != [], do: state.report.meta.timings_ms.baseline),
        mutant_deadline_ms: if(added != [], do: state.report.meta.timings_ms[:mutant_deadline])
      }

      result = if state.stopped, do: :stop, else: :ok
      {result, %{state | escalation: [step | state.escalation]}}
    end
  end

  defp admit(candidates, timeout, state, phases) do
    state = %{state | tried: Enum.reduce(candidates, state.tried, &MapSet.put(&2, &1))}

    Enum.reduce_while(candidates, {:ok, [], state}, fn path, {:ok, accepted, state} ->
      filter = %{state.filter | files: [path]}
      input = %{test_filter: filter, escalation_timeout_ms: timeout}

      case probe_candidate(input, state, phases) do
        {{:ok, _baseline, _report}, _attempted?, effects} ->
          {:cont, {:ok, [path | accepted], put_in(state.loads[path], effects)}}

        {{:abort, _report, _, reason, _details}, attempted?, _effects}
        when reason in @candidate_errors ->
          if reason == :test_file_load_failed, do: ExUnitServer.discard_pending_modules()

          state =
            if attempted?,
              do: reject_loaded(state, path, reason),
              else: reject(state, path, reason)

          {:cont, {:ok, accepted, state}}

        {{:abort, _, _, _, _} = abort, _attempted?, _effects} ->
          {:halt, abort}
      end
    end)
    |> case do
      {:ok, accepted, state} -> {:ok, Enum.reverse(accepted), state}
      abort -> abort
    end
  end

  # Capture load-time changes separately from changes made by test bodies.
  defp probe_candidate(input, state, {mod, phases}) do
    before = environment()
    caller = self()
    ref = make_ref()

    loader = fn file ->
      send(caller, {ref, :loading})
      result = Code.require_file(file)
      send(caller, {ref, environment()})
      result
    end

    try do
      outcome = mod.baseline(phases, Map.put(input, :test_loader, loader), state.report)

      attempted? =
        receive do
          {^ref, :loading} -> true
        after
          0 -> false
        end

      after_load =
        receive do
          {^ref, env} -> env
        after
          0 -> before
        end

      changes =
        Map.reject(after_load, fn {key, value} -> Map.fetch(before, key) == {:ok, value} end)

      {outcome, attempted?, {Map.keys(before) -- Map.keys(after_load), changes}}
    after
      restore_environment(before)
    end
  end

  defp with_file_env(state, files, run) do
    before = environment()

    selected =
      Enum.reduce(files, before, fn file, env ->
        {removed, changed} = Map.fetch!(state.loads, file)
        env |> Map.drop(removed) |> Map.merge(changed)
      end)

    try do
      restore_environment(selected)
      run.()
    after
      restore_environment(before)
    end
  end

  defp environment do
    for {app, _, _} <- Application.loaded_applications(),
        {key, value} <- Application.get_all_env(app),
        into: System.get_env() do
      {{app, key}, value}
    end
  end

  defp restore_environment(target) do
    current = environment()

    for key <- Map.keys(current) -- Map.keys(target), do: delete_env(key)

    for {key, value} <- target, Map.fetch(current, key) != {:ok, value}, do: put_env(key, value)

    :ok
  end

  defp delete_env({app, key}), do: Application.delete_env(app, key)
  defp delete_env(key), do: System.delete_env(key)

  defp put_env({app, key}, value), do: Application.put_env(app, key, value)
  defp put_env(key, value), do: System.put_env(key, value)

  defp candidate_timeout(config, baseline_ms) do
    ceiling = min(config.boot_timeout_ms, config.timeout_ms)
    min(ceiling, max(to_timeout(second: 30), 10 * baseline_ms))
  end

  defp run_stage(_step, [], _plan, _config, _timeout, state, _phases), do: {:ok, state, []}

  defp run_stage(step, files, plan, config, timeout, state, phases) do
    case combined_baseline(files, config, timeout, state, phases) do
      {:ok, input, report} ->
        run_green_stage(step, plan, config, state, input, report, phases)

      {:abort, _, _, reason, _} when reason in @candidate_errors ->
        with {:ok, state, accepted} <- admit_combined(files, config, timeout, state, phases) do
          case accepted do
            {input, report} -> run_green_stage(step, plan, config, state, input, report, phases)
            nil -> {:ok, state, []}
          end
        end

      abort ->
        abort
    end
  end

  defp admit_combined(files, config, timeout, state, phases) do
    Enum.reduce_while(files, {:ok, state, nil}, fn path, {:ok, state, accepted} ->
      prefix = if accepted, do: elem(accepted, 0).test_filter.files, else: []

      case combined_baseline(prefix ++ [path], config, timeout, state, phases) do
        {:ok, input, report} ->
          {:cont, {:ok, state, {input, report}}}

        {:abort, _, _, :baseline_red, _} ->
          {:cont, {:ok, reject_loaded(state, path, :baseline_red_in_combination), accepted}}

        {:abort, _, _, reason, _} when reason in @candidate_errors ->
          {:cont, {:ok, reject_loaded(state, path, reason), accepted}}

        abort ->
          {:halt, abort}
      end
    end)
  end

  defp combined_baseline(files, config, timeout, state, {mod, phases}) do
    filter = %{state.filter | files: files}
    modules = TestModuleDiscovery.discover(files)
    input = %{test_filter: filter, test_modules: modules}
    timeout = min(config.boot_timeout_ms, timeout * length(files))

    with_file_env(state, files, fn ->
      case mod.baseline(phases, Map.put(input, :escalation_timeout_ms, timeout), state.report) do
        {:ok, _baseline, report} -> {:ok, input, report}
        abort -> abort
      end
    end)
  end

  defp run_green_stage(step, plan, config, state, input, report, phases) do
    with_file_env(state, input.test_filter.files, fn ->
      run_green_files(step, plan, config, state, input, report, phases)
    end)
  end

  defp run_green_files(step, plan, config, state, input, report, {mod, phases} = execution) do
    %{test_filter: filter, test_modules: modules} = input

    with {:ok, coverage, report} <- mod.coverage(phases, plan[:scopes], filter, modules, report) do
      sites =
        Enum.filter(remaining_sites(plan, state), fn site ->
          match?(%{status: :survived}, state.results[site.id]) or
            MutationEnumerator.covered?(site, coverage.covered_lines)
        end)

      why = if step == :module, do: :escalation_module, else: :escalation_function
      selection = state.selection ++ Enum.map(filter.files, &%{path: &1, why: why})

      state = %{
        state
        | report: report,
          selection: selection,
          files: Enum.uniq(state.files ++ filter.files),
          no_tests: nil,
          coverage:
            Map.merge(state.coverage, coverage.covered_lines, fn _, a, b -> MapSet.union(a, b) end)
      }

      with {:ok, state} <- mutate(step, plan, sites, config, state, input, execution) do
        {:ok, state, filter.files}
      end
    else
      {:abort, _, _, reason, _} when reason in @coverage_errors ->
        state = Enum.reduce(filter.files, state, &reject_loaded(&2, &1, reason))
        {:ok, %{state | stopped: reason}, []}

      abort ->
        abort
    end
  end

  defp reject_loaded(state, path, reason) do
    state = update_in(state.dropped_files, &MapSet.put(&1, path))
    reject(state, path, reason)
  end

  defp reject(state, path, reason) do
    warning =
      case reason do
        :baseline_red -> :escalation_baseline_red
        :baseline_red_in_combination -> :escalation_baseline_red_in_combination
        :baseline_timeout -> :escalation_baseline_timeout
        :test_file_load_failed -> :escalation_test_file_load_failed
        :test_read_failed -> :escalation_test_read_failed
        :no_tests_run -> :escalation_no_tests_run
        :ex_unit_run_failed -> :escalation_baseline_crashed
        reason when reason in @coverage_errors -> :escalation_coverage_failed
      end

    update_in(state.rejected, &Map.update(&1, warning, [path], fn paths -> [path | paths] end))
  end

  defp mutate(_step, _plan, [], _config, state, _input, _phases), do: {:ok, state}

  defp mutate(step, plan, entries, config, state, input, {mod, phases}) do
    sites = Enum.map(entries, &MutationEnumerator.to_site(Map.delete(&1, :in_scope)))
    budget = config.budget_ms && max(0, config.budget_ms - state.mutation_ms)
    started = System.monotonic_time(:millisecond)

    if budget == 0 do
      {:ok, %{state | truncated: true}}
    else
      input = Map.put(input, :tainted_predecessors, state.tainted)

      with {:ok, result, report} <- mod.mutation(phases, plan, input, sites, budget, state.report) do
        state = %{state | report: report, mutation_ms: state.mutation_ms + elapsed(started)}
        {:ok, record_run(state, step, result)}
      end
    end
  end

  defp record_run(state, step, outcome) do
    results =
      Map.new(outcome.results, fn result ->
        previous = get_in(state.results, [result.id, :selection, :steps_run]) || []
        killed_at = if result.status == :killed, do: step
        selection = %{killed_at: killed_at, steps_run: previous ++ [step]}

        selection =
          if MapSet.size(state.dropped_files) > 0,
            do: Map.put(selection, :after_dropped_file, true),
            else: selection

        {result.id, Map.put(result, :selection, selection)}
      end)

    errors = Map.new(outcome.compile_errors, &{&1.id, &1})
    dropped = Map.get(outcome, :dropped, [])
    replaced = Map.keys(errors) ++ Enum.map(dropped, & &1.id)

    %{
      warn(state, outcome.warnings)
      | results: state.results |> Map.drop(replaced) |> Map.merge(results),
        compile_errors: state.compile_errors |> Map.drop(Map.keys(results)) |> Map.merge(errors),
        dropped: state.dropped ++ dropped,
        drift: Map.merge(state.drift, outcome.state_drift_warning),
        truncated: Map.get(outcome, :truncated, false),
        tainted: Map.get(outcome, :tainted, false)
    }
  end

  defp complete(plan, state) do
    results = collect(plan.sites, state.results)
    compile_errors = collect(plan.sites, state.compile_errors)

    partitions =
      MutationEnumerator.partition_planned_runtime_sites(plan.sites, %{
        results: results,
        compile_errors: compile_errors,
        skipped: []
      })

    pending =
      Enum.map(partitions.uncovered_candidate, fn site ->
        pending_site(
          site,
          if(MutationEnumerator.covered?(site, state.coverage), do: :not_run, else: :uncovered)
        )
      end)

    not_run = Enum.map(partitions.not_run, &pending_site(&1, :not_run))

    rejected =
      for {reason, paths} <- Enum.sort(state.rejected) do
        {:escalation_rejected, reason, Enum.reverse(paths)}
      end

    red =
      [:escalation_baseline_red, :escalation_baseline_red_in_combination]
      |> Enum.flat_map(&Map.get(state.rejected, &1, []))

    report = %{
      state.report
      | tests: add_test_files(state.report.tests, state.files),
        warnings: state.report.warnings ++ List.wrap(state.no_tests) ++ rejected,
        coverage: %{
          covered_lines: state.coverage,
          suite_stats: get_in(state.report.coverage, [:suite_stats])
        },
        baseline: state.report.baseline || %{passed: 0, failed: 0, failures: []},
        truncated: state.truncated
    }

    meta =
      if plan[:meta] do
        incomplete = plan.incomplete ++ Enum.map(state.dropped, &Map.take(&1, [:reason, :path]))

        evaluated = MapSet.new(results ++ compile_errors, & &1.id)
        uncovered = ChangedScope.uncovered_lines(plan, state.coverage, evaluated)

        report.meta
        |> Map.put(:since, %{plan.meta | run: MapSet.size(evaluated), uncovered: uncovered})
        |> Map.put(:incomplete_reasons, Enum.uniq(incomplete))
      else
        report.meta
      end

    meta =
      if plan.selection do
        meta
        |> Map.put(:tests_selected, state.selection)
        |> Map.put(:escalation, Enum.reverse(state.escalation))
      else
        meta
      end

    outcome = %{
      results: results,
      compile_errors: compile_errors,
      state_drift_warning: state.drift,
      pending: pending ++ not_run
    }

    meta = Map.put(meta, :red_functions, AutoTests.mentioned_functions(red, plan.sites))

    meta =
      if state.stopped do
        reason = %{reason: :escalation_stopped, path: nil}
        Map.update(meta, :incomplete_reasons, [reason], &(&1 ++ [reason]))
      else
        meta
      end

    {:ok, %{report | meta: meta}, outcome}
  end

  defp add_test_files(nil, _files), do: nil
  defp add_test_files(tests, files), do: %{tests | files: files}

  defp collect(entries, outcomes) do
    for entry <- entries, outcome = Map.get(outcomes, entry.id), outcome != nil do
      annotate(outcome, entry)
    end
  end

  defp pending_site(entry, reason) do
    entry
    |> Map.take([:id, :file, :line, :column, :mutator, :function, :in_scope])
    |> Map.put(:reason, reason)
  end

  defp annotate(outcome, %{in_scope: reason}), do: Map.put(outcome, :in_scope, reason)

  defp annotate(outcome, _entry), do: outcome

  defp remaining_sites(plan, state) do
    terminal = MapSet.new(state.dropped, & &1.id)

    Enum.filter(plan.sites, fn site ->
      case state.results[site.id] do
        %{status: status} ->
          status in [:survived, :uncovered]

        nil ->
          not MutationEnumerator.covered?(site, state.coverage) and
            not Map.has_key?(state.compile_errors, site.id) and
            not MapSet.member?(terminal, site.id)
      end
    end)
  end

  defp survivors(state) do
    state.results |> Map.values() |> Enum.filter(&(&1.status == :survived))
  end

  defp warn(state, warnings) do
    update_in(state.report.warnings, &(&1 ++ List.wrap(warnings)))
  end

  defp elapsed(started), do: System.monotonic_time(:millisecond) - started
end
