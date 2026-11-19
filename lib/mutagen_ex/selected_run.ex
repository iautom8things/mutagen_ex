defmodule MutagenEx.SelectedRun do
  @moduledoc false

  alias MutagenEx.{AutoTests, MutationEnumerator, TestModuleDiscovery}
  alias MutagenEx.Test.ExUnitServer

  def run(plan, report, config, filter, test_paths, phases) do
    state = %{
      report: report,
      filter: filter,
      selection: plan.selection,
      tried: MapSet.new(filter.files),
      rejected: %{},
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

    with {:ok, state} <- narrow(plan, config, state, phases),
         narrow_timing = state.report.meta.timings_ms,
         {:ok, state} <- escalate(plan, config, state, test_paths, phases) do
      state = put_in(state.report.meta.timings_ms, %{narrow_timing | mutation: state.mutation_ms})
      complete(plan, state)
    end
  end

  defp narrow(%{sites: []}, _config, state, _phases), do: {:ok, state}

  defp narrow(_plan, _config, %{filter: %{files: []}} = state, _phases) do
    {:ok, warn(state, "no_tests_run")}
  end

  defp narrow(plan, config, state, phases) do
    case phases.coverage.(state.filter, nil, state.report) do
      {:ok, coverage, report} ->
        state = %{state | report: report, coverage: coverage.covered_lines}

        with {:ok, input} <- phases.test_input.(coverage, state.filter, report),
             {:ok, _baseline, report} <- phases.baseline.(input, report) do
          sites = Enum.filter(plan.sites, &covered?(&1, state.coverage))
          mutate(:narrow, sites, config, %{state | report: report}, input, phases)
        end

      {:abort, report, _, :no_tests_run, details} ->
        warning =
          "no_tests_run: coverage excluded #{details[:excluded] || 0}, skipped #{details[:skipped] || 0}"

        {:ok, warn(%{state | report: report}, warning)}

      abort ->
        abort
    end
  end

  defp escalate(plan, %{tests: ["auto"], escalate: true} = config, state, test_paths, phases) do
    Enum.reduce_while([:module, :function], {:ok, state}, fn stage, {:ok, current} ->
      survivors = survivors(current)

      if survivors == [] or current.truncated do
        {:halt, {:ok, current}}
      else
        case escalate_stage(stage, survivors, plan, config, current, test_paths, phases) do
          {:ok, next} -> {:cont, {:ok, next}}
          abort -> {:halt, abort}
        end
      end
    end)
  end

  defp escalate(_plan, _config, state, _test_paths, _phases), do: {:ok, state}

  defp escalate_stage(stage, survivors, plan, config, state, test_paths, phases) do
    started = System.monotonic_time(:millisecond)

    {candidates, capped?} =
      AutoTests.discover(stage, survivors, test_paths, state.tried, config.escalate_max_files)

    with {:ok, files, state} <- admit(candidates, state, phases),
         {:ok, state, added} <- run_stage(stage, files, plan, config, state, phases) do
      step = %{
        step: stage,
        files_added: added,
        capped: capped?,
        survivors_in: length(survivors),
        survivors_out: length(survivors(state)),
        wall_ms: elapsed(started),
        baseline_ms: if(added == [], do: 0, else: state.report.meta.timings_ms.baseline),
        mutant_deadline_ms: if(added != [], do: state.report.meta.timings_ms[:mutant_deadline])
      }

      {:ok, %{state | escalation: [step | state.escalation]}}
    end
  end

  defp admit(candidates, state, phases) do
    state = %{state | tried: Enum.reduce(candidates, state.tried, &MapSet.put(&2, &1))}

    candidates
    |> Enum.reduce_while({:ok, [], state}, fn path, {:ok, accepted, state} ->
      filter = %{state.filter | files: [path]}

      case phases.baseline.(%{test_filter: filter}, state.report) do
        {:ok, _baseline, _report} ->
          {:cont, {:ok, [path | accepted], state}}

        {:abort, _report, _, reason, _details}
        when reason in [:baseline_red, :test_file_load_failed, :no_tests_run] ->
          # A file can register a case and then fail to load.
          ExUnitServer.discard_pending_modules()
          {:cont, {:ok, accepted, reject(state, path, reason)}}

        abort ->
          {:halt, abort}
      end
    end)
    |> case do
      {:ok, files, state} -> {:ok, Enum.reverse(files), state}
      abort -> abort
    end
  end

  defp run_stage(_step, [], _plan, _config, state, _phases), do: {:ok, state, []}

  defp run_stage(step, files, plan, config, state, phases) do
    filter = %{state.filter | files: files}
    modules = TestModuleDiscovery.discover(files)
    input = %{test_filter: filter, test_modules: modules}

    # Baseline the files together to measure the pass and catch interactions.
    case phases.baseline.(input, state.report) do
      {:ok, _baseline, report} ->
        run_green_stage(step, plan, config, state, input, report, phases)

      {:abort, _report, _, :baseline_red, _details} ->
        {:ok, Enum.reduce(files, state, &reject(&2, &1, :baseline_red)), []}

      abort ->
        abort
    end
  end

  defp run_green_stage(step, plan, config, state, input, report, phases) do
    %{test_filter: filter, test_modules: modules} = input

    with {:ok, coverage, report} <- phases.coverage.(filter, modules, report) do
      sites =
        Enum.filter(plan.sites, fn %{id: id} = site ->
          case state.results do
            %{^id => %{status: :survived}} ->
              true

            _ ->
              not covered?(site, state.coverage) and covered?(site, coverage.covered_lines)
          end
        end)

      why = if step == :module, do: :escalation_module, else: :escalation_function
      selection = state.selection ++ Enum.map(filter.files, &%{path: &1, why: why})

      state = %{
        state
        | report: report,
          selection: selection,
          coverage:
            Map.merge(state.coverage, coverage.covered_lines, fn _, a, b -> MapSet.union(a, b) end)
      }

      with {:ok, state} <- mutate(step, sites, config, state, input, phases) do
        {:ok, state, filter.files}
      end
    end
  end

  defp reject(state, path, reason) do
    warning =
      case reason do
        :baseline_red -> :escalation_baseline_red
        :test_file_load_failed -> :escalation_test_file_load_failed
        :no_tests_run -> :escalation_no_tests_run
      end

    update_in(state.rejected, &Map.update(&1, warning, [path], fn paths -> [path | paths] end))
  end

  defp mutate(_step, [], _config, state, _input, _phases), do: {:ok, state}

  defp mutate(step, entries, config, state, input, phases) do
    sites = Enum.map(entries, &MutationEnumerator.to_site(Map.delete(&1, :in_scope)))
    budget = config.budget_ms && max(0, config.budget_ms - state.mutation_ms)
    started = System.monotonic_time(:millisecond)

    if budget == 0 do
      {:ok, %{state | truncated: true}}
    else
      input = Map.put(input, :tainted_predecessors, state.tainted)

      with {:ok, result, report} <- phases.mutation.(input, sites, budget, state.report) do
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
        {result.id, Map.put(result, :selection, selection)}
      end)

    errors = Map.new(outcome.compile_errors, &{&1.id, &1})
    dropped = Map.get(outcome, :dropped, [])
    replaced = Map.keys(errors) ++ Enum.map(dropped, & &1.id)

    %{
      warn(state, outcome.warnings)
      | results: state.results |> Map.drop(replaced) |> Map.merge(results),
        compile_errors: Map.merge(state.compile_errors, errors),
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
        pending_site(site, if(covered?(site, state.coverage), do: :not_run, else: :uncovered))
      end)

    not_run = Enum.map(partitions.not_run, &pending_site(&1, :not_run))

    rejected =
      for {reason, paths} <- Enum.sort(state.rejected) do
        {:escalation_rejected, reason, Enum.reverse(paths)}
      end

    report = %{
      state.report
      | warnings: state.report.warnings ++ rejected,
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

        report.meta
        |> Map.put(:since, %{plan.meta | run: length(results) + length(compile_errors)})
        |> Map.put(:incomplete, Enum.uniq(incomplete))
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

    {:ok, %{report | meta: meta}, outcome}
  end

  defp collect(entries, outcomes) do
    for entry <- entries, outcome = Map.get(outcomes, entry.id), outcome != nil do
      annotate(outcome, entry)
    end
  end

  defp pending_site(entry, reason), do: entry |> Map.put(:reason, reason) |> annotate(entry)

  defp annotate(outcome, %{in_scope: reason} = entry) do
    Map.merge(outcome, %{
      in_scope: reason,
      fingerprint: MutationEnumerator.site_fingerprint(entry)
    })
  end

  defp annotate(outcome, _entry), do: outcome

  defp survivors(state) do
    state.results |> Map.values() |> Enum.filter(&(&1.status == :survived))
  end

  defp covered?(%{file: file} = site, bitmap) do
    case bitmap do
      %{^file => lines} -> MapSet.member?(lines, site.line)
      _ -> false
    end
  end

  defp warn(state, warnings) do
    update_in(state.report.warnings, &(&1 ++ List.wrap(warnings)))
  end

  defp elapsed(started), do: System.monotonic_time(:millisecond) - started
end
