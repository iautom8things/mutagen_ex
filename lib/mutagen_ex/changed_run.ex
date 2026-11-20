defmodule MutagenEx.ChangedRun do
  @moduledoc false

  alias MutagenEx.{AutoTests, ChangedScope, JsonStreamer, MutationEnumerator, MutationRunner}
  alias MutagenEx.{Runtime, SelectedRun, TestSelector}
  alias MutationEnumerator.Site
  alias TestSelector.TestFilter

  def run(%{since: nil} = config, report, phases) do
    phases.boot.(report, fn report, state ->
      paths = project_paths(state.test_paths)
      roots = source_roots(paths)

      with {:ok, scopes} <- phases.scope.(report, roots),
           report = %{report | scope: scopes},
           {:ok, cache} <- phases.ast_cache.(scopes, empty_filter(), report) do
        lines =
          for {file, records} <- Enum.group_by(scopes, & &1.file), into: %{} do
            {file, [{1, Enum.max_by(records, & &1.line_range.last).line_range.last}]}
          end

        %{sites: sites, skipped: skipped} =
          MutationEnumerator.enumerate(cache, scopes, %{}, planned: lines, source: config.source)

        sites = Enum.filter(sites, & &1.runtime?)
        skipped = Enum.filter(skipped, & &1.runtime?)

        with {:ok, plan} <-
               select_site(
                 %{scopes: scopes, cache: cache, sites: sites, skipped: skipped},
                 config,
                 report
               ),
             :ok <- check_scope(plan.scopes, config, report),
             :ok <- check_site_cap(plan, config, report) do
          selection =
            if config.tests == ["auto"], do: AutoTests.select(plan.scopes, roots, paths, [])

          run_selected(Map.put(plan, :selection, selection), config, report, phases, state)
        end
      end
    end)
  end

  def run(config, report, phases) do
    with :ok <- Runtime.check_project(phases.command),
         paths = project_paths(Runtime.test_paths()),
         roots = source_roots(paths),
         {:ok, plan} <- ChangedScope.plan(config, roots, exclude: excluded_roots(paths)) do
      report = changed_report(report, plan)

      with {:ok, plan} <- select_site(plan, config, report),
           :ok <- check_scope(plan.scopes, config, report),
           :ok <- check_site_cap(plan, config, report) do
        prepare_tests(plan, config, report, phases, roots, paths)
      end
    else
      {:error, reason, details, plan} ->
        {:abort, changed_report(report, plan), config, reason, details}

      {:error, reason, details} ->
        abort(report, config, reason, details)
    end
  end

  defp prepare_tests(plan, config, report, phases, roots, paths) do
    discovery =
      if config.tests == ["auto"] and paths != [],
        do: ChangedScope.changed_tests(plan, paths),
        else: {:ok, [], []}

    case discovery do
      {:ok, changed, skipped} ->
        selection =
          if config.tests == ["auto"], do: AutoTests.select(plan.scopes, roots, paths, changed)

        plan = Map.put(%{plan | incomplete: plan.incomplete ++ skipped}, :selection, selection)
        report = changed_report(report, plan)

        if plan.sites == [] or (selection == [] and (not config.escalate or paths == [])) do
          run_selected(plan, config, report, phases, %{test_paths: paths, exunit: []})
        else
          phases.boot.(report, &run_selected(plan, config, &1, phases, &2))
        end

      {:error, reason, details} ->
        abort(report, config, reason, details)
    end
  end

  defp source_roots(paths) do
    (Mix.Project.config()[:elixirc_paths] || ["lib"])
    |> project_paths()
    |> Enum.reject(&ChangedScope.excluded?(&1, excluded_roots(paths)))
  end

  defp excluded_roots(paths), do: ["test/support" | paths]

  defp project_paths(paths) do
    cwd = File.cwd!()
    paths |> Enum.map(&Path.relative_to(Path.expand(&1), cwd)) |> Enum.uniq()
  end

  defp changed_report(report, plan) do
    meta =
      Map.merge(report.meta, %{since: plan.meta, incomplete_reasons: Enum.uniq(plan.incomplete)})

    meta =
      case plan do
        %{selection: selection} when is_list(selection) ->
          Map.merge(meta, %{tests_selected: selection, escalation: []})

        _ ->
          meta
      end

    warnings =
      if plan[:sites] == [] and plan.meta.changed_files > 0,
        do: (plan.warnings -- [:empty_diff]) ++ [:no_runtime_sites],
        else: plan.warnings

    %{
      report
      | meta: meta,
        scope: Map.get(plan, :scopes, []),
        warnings: Enum.map(warnings, &to_string/1)
    }
  end

  defp abort(report, config, reason, details)
       when reason in [:diff_unavailable, :invalid_since_ref],
       do:
         {:abort, report, config, reason,
          Map.take(details, [:cause, :shallow, :root, :limit_files])}

  defp abort(report, config, reason, details), do: {:abort, report, config, reason, details}

  defp check_scope(scopes, config, report) do
    case MutationRunner.check_scope(scopes) do
      :ok ->
        :ok

      {:error, reason, details} ->
        abort(report, config, reason, details)
    end
  end

  defp select_site(plan, %{site: nil}, _report), do: {:ok, plan}

  defp select_site(plan, config, report) do
    case Enum.filter(plan.sites, &Site.matches?(&1.id, config.site)) do
      [site | _] ->
        scopes = Enum.filter(plan.scopes, &(&1.file == site.file))
        {:ok, %{plan | sites: [site], skipped: [], scopes: scopes}}

      [] ->
        abort(report, config, :site_not_found, %{step: :enumeration})
    end
  end

  defp check_site_cap(plan, config, report) do
    count = length(plan.sites)

    if count > config.max_sites do
      abort(report, config, :too_many_sites, %{
        step: :enumeration,
        count: count,
        cap: config.max_sites
      })
    else
      :ok
    end
  end

  defp run_selected(plan, config, report, phases, state) do
    with {:ok, filter} <- selected_filter(plan, phases, report, state) do
      tests = filter |> phases.report_tests.() |> Map.put(:host_paths?, plan.selection != nil)
      report = %{report | tests: tests}
      paths = project_paths(state.test_paths)

      with {:ok, report, outcome} <-
             SelectedRun.run(plan, report, config, filter, paths, phases.phases.(plan, state)) do
        mutation =
          phases.report_mutation.(outcome, plan)
          |> Map.put(:pending, pending_for_summary(outcome.pending, plan))

        report = %{report | mutation: mutation}
        if config.stream, do: emit_stream(config, phases.stream_sink.(), plan, report)
        {:ok, report, config}
      end
    end
  end

  defp pending_for_summary([], _plan), do: []

  defp pending_for_summary(pending, plan) do
    sites = Map.new(plan.sites, &{&1.id, &1})

    Enum.map(pending, fn %{id: id, file: file} = entry ->
      site = Map.fetch!(sites, id)
      {_ast, source} = Map.fetch!(plan.cache, file)

      site
      |> Map.take([
        :definition_line,
        :original_ast,
        :mutated_ast,
        :end_line,
        :end_column,
        :source_span,
        :source_line
      ])
      |> Map.put(:source_text, source)
      |> Map.merge(entry)
    end)
  end

  defp empty_filter, do: %TestFilter{include: [], exclude: [], files: []}

  defp selected_filter(plan, phases, report, state) do
    selected =
      cond do
        plan.selection != nil ->
          {:ok, %{empty_filter() | files: Enum.map(plan.selection, & &1.path)}}

        plan.sites == [] ->
          {:ok, empty_filter()}

        true ->
          phases.tests.(report, state.test_paths)
      end

    with {:ok, filter} <- selected do
      {:ok,
       TestSelector.merge_helper_filters(
         filter,
         state.exunit,
         Map.get(state, :helper_tags, MapSet.new())
       )}
    end
  end

  defp emit_stream(config, sink, plan, report) do
    %{results: results, compile_errors: errors} = report.mutation
    by_id = Map.new(results, &{&1.id, {:result, &1}})
    by_id = Enum.into(errors, by_id, &{&1.id, {:compile_error, &1}})

    Process.put(:mutagen_stream_open, true)
    JsonStreamer.emit_start(sink, map_size(by_id), report.meta, config)

    for site <- plan.sites do
      case by_id[site.id] do
        {:result, result} -> JsonStreamer.emit_result(sink, result, config)
        {:compile_error, entry} -> JsonStreamer.emit_compile_error(sink, entry, config)
        nil -> :ok
      end
    end
  end
end
