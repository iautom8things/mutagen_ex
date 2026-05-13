defmodule MutagenEx.MutationRunner do
  @moduledoc """
  Per-mutation execution: swap → run → classify → restore. Aggregates the
  per-site outcomes into a result block the JSON reporter (S6) can
  serialise.

  Contract: [`mutagen.mutation_pipeline`](../../.spec/specs/mutation_pipeline.spec.md)
  r3-r11.

  ## Invariants summary

    * **r3** — refuses to mutate `MutagenEx.*` or `Mix.Tasks.Mutagen`
      modules (see [`mutagen.decision.self_mutation_refused`](../../.spec/decisions/self_mutation_refused.md)).
    * **r4** — per-site test runs wrap `ExUnit.run/0` in the timeout
      structure owned by `MutagenEx.MutationRunner.MutationLoop`. Timed-
      out sites are classified `:timeout` and the following site carries
      `tainted_predecessors: true`.
    * **r5** — exactly five outcomes: `:killed`, `:survived`, `:timeout`,
      `:compile_error`, `:error`. `:compile_error` does not count toward
      the kill-rate denominator.
    * **r6** — after every per-site run, the original module is restored
      via `Code.compile_quoted(cached_ast, file)`. On restore failure the
      runner aborts with `{:error, :unrecoverable_restore_failure, ...}`.
    * **r7** — pre/post state snapshots
      (`Process.registered/0`, `:ets.all/0`, `:persistent_term.info/0`).
      Growth flags `tainted_predecessors: true` for subsequent results
      and emits a warning naming the new entities (best-effort —
      `Process.registered/0` is the named-process surface; anonymous
      leaks are documented as a known caveat per
      [`mutagen.decision.timeout_handling`](../../.spec/decisions/timeout_handling.md)).
    * **r8** — modules whose AST contains `use SomeModule` get a
      `state_drift_warning` listing the used modules.
    * **r9** — stderr is captured via `ExUnit.CaptureIO` and attached
      to each result's `warnings` field.
    * **r10** — test files are loaded once (the orchestrator's
      responsibility upstream); per-site cycles re-register modules via
      `ExUnit.Server.add_module/2` from `MutationLoop`.
    * **r11** — no file on disk is modified by the runner. All AST
      compilation is in-memory via `Code.compile_quoted/2`.

  ## Input shape

  `run/1` takes a map:

    * `:seed` — `non_neg_integer`. Forwarded to ExUnit.configure for the
      duration of the runner.
    * `:timeout_ms` — `pos_integer`. Per-site wall-clock budget.
    * `:test_filter` — `%MutagenEx.TestSelector.TestFilter{}`.
    * `:ast_cache` — `%{file => {ast, source_text}}` from
      `MutagenEx.AstCache.load/1`.
    * `:sites` — `[%MutagenEx.MutationEnumerator.Site{}, ...]`.
    * `:scope_records` — `[%MutagenEx.ScopeResolver.Scope{}]`, used for
      r8 (state-drift detection over `use SomeModule` in scoped modules).
    * `:test_modules` — `[{module, exunit_module_cfg}]` to re-register
      between per-site runs. Built by the orchestrator from the test
      filter once before the runner starts.

  Optional:

    * `:ex_unit`, `:ex_unit_server`, `:capture_io` — module-level seams
      passed through to `MutationLoop`. Default: the real Elixir modules.
    * `:compiler` — `{module, fun}` to use instead of
      `Code.compile_quoted/2`. Test seam.

  ## Output shape

  `{:ok, %{results: [...], compile_errors: [...], state_drift_warning: %{...}, warnings: [...]}}`
  on full pipeline. `{:error, reason, details}` on `:self_mutation_refused`
  or `:unrecoverable_restore_failure`.
  """

  alias MutagenEx.AstCache
  alias MutagenEx.MutationEnumerator.Site
  alias MutagenEx.MutationRunner.MutationLoop
  alias MutagenEx.ScopeResolver.Scope
  alias MutagenEx.TestSelector.TestFilter

  @self_mutation_prefix "Elixir.MutagenEx."
  @self_mutation_task "Elixir.Mix.Tasks.Mutagen"

  @typedoc "Reasons the runner can abort with."
  @type error_reason ::
          :self_mutation_refused
          | :unrecoverable_restore_failure
          | :invalid_input

  @typedoc "Successful per-site result. `:compile_error` outcomes live in `compile_errors` instead."
  @type site_result :: %{
          id: String.t(),
          file: String.t(),
          line: pos_integer(),
          column: pos_integer(),
          mutator: atom(),
          original_ast: Macro.t(),
          mutated_ast: Macro.t(),
          status: :killed | :survived | :timeout | :error,
          tainted_predecessors: boolean(),
          warnings: [String.t()]
        }

  @typedoc "Compile-error record (sites whose mutated AST refused to compile)."
  @type compile_error_entry :: %{
          id: String.t(),
          file: String.t(),
          line: pos_integer(),
          column: pos_integer(),
          mutator: atom(),
          message: String.t()
        }

  @typedoc "Aggregated runner result."
  @type ok_result :: %{
          results: [site_result()],
          compile_errors: [compile_error_entry()],
          state_drift_warning: %{optional(module()) => [atom()]},
          warnings: [String.t()]
        }

  @doc """
  Runs the mutation phase. See module doc for input shape.
  """
  @spec run(map()) :: {:ok, ok_result()} | {:error, error_reason(), map()}
  def run(input) when is_map(input) do
    with {:ok, cfg} <- normalise(input),
         :ok <- ensure_no_self_mutation(cfg) do
      :ok = configure_exunit(cfg)
      drift = compute_state_drift_warnings(cfg)
      execute(cfg, drift)
    end
  end

  # ---------------------------------------------------------------------------
  # r3: self-mutation refusal
  # ---------------------------------------------------------------------------

  defp ensure_no_self_mutation(cfg) do
    offenders =
      cfg.scope_records
      |> Enum.map(& &1.module)
      |> Enum.filter(&self_mutation?/1)

    case offenders do
      [] ->
        :ok

      _ ->
        {:error, :self_mutation_refused,
         %{
           modules: offenders,
           message:
             "mutagen_ex refuses to mutate its own runtime: " <>
               Enum.map_join(offenders, ", ", &inspect/1) <>
               ". " <>
               "See mutagen.decision.self_mutation_refused."
         }}
    end
  end

  defp self_mutation?(mod) when is_atom(mod) do
    str = Atom.to_string(mod)

    String.starts_with?(str, @self_mutation_prefix) or str == @self_mutation_task
  end

  defp self_mutation?(_), do: false

  # ---------------------------------------------------------------------------
  # ExUnit config (r2's force, shared with baseline/coverage)
  # ---------------------------------------------------------------------------

  defp configure_exunit(cfg) do
    ex_unit = Map.get(cfg, :ex_unit, ExUnit)

    apply(ex_unit, :configure, [
      [
        max_cases: 1,
        seed: cfg.seed,
        include: cfg.test_filter.include,
        exclude: cfg.test_filter.exclude
      ]
    ])

    :ok
  end

  # ---------------------------------------------------------------------------
  # r8: state drift warnings — modules with `use SomeModule`
  # ---------------------------------------------------------------------------

  defp compute_state_drift_warnings(cfg) do
    cfg.scope_records
    |> Enum.reduce(%{}, fn %Scope{file: file, module: module}, acc ->
      case AstCache.get(cfg.ast_cache, file) do
        :error ->
          acc

        {:ok, {ast, _source}} ->
          uses = uses_in_module_ast(ast, module)

          if uses == [] do
            acc
          else
            Map.put(acc, module, uses)
          end
      end
    end)
  end

  defp uses_in_module_ast(ast, target_mod) do
    case find_module_body(ast, target_mod) do
      :not_found ->
        []

      {:ok, body} ->
        {_, list} =
          Macro.prewalk(body, [], fn
            {:use, _meta, [used | _rest]} = node, acc ->
              case alias_to_module(used) do
                nil -> {node, acc}
                mod -> {node, [mod | acc]}
              end

            node, acc ->
              {node, acc}
          end)

        list |> Enum.reverse() |> Enum.uniq()
    end
  end

  defp find_module_body(ast, target_mod) do
    {_ast, acc} =
      Macro.prewalk(ast, :not_found, fn
        {:defmodule, _meta, [alias_ast, [do: body]]} = node, :not_found ->
          case alias_to_module(alias_ast) do
            ^target_mod -> {node, {:ok, body}}
            _ -> {node, :not_found}
          end

        node, acc ->
          {node, acc}
      end)

    acc
  end

  defp alias_to_module({:__aliases__, _, parts}) when is_list(parts) do
    if Enum.all?(parts, &is_atom/1), do: Module.concat(parts), else: nil
  end

  defp alias_to_module(mod) when is_atom(mod), do: mod
  defp alias_to_module(_), do: nil

  # ---------------------------------------------------------------------------
  # Main per-site loop
  # ---------------------------------------------------------------------------

  defp execute(cfg, drift) do
    initial = %{
      results: [],
      compile_errors: [],
      state_drift_warning: drift,
      warnings: [],
      tainted: false
    }

    Enum.reduce_while(cfg.sites, {:ok, initial}, fn site, {:ok, acc} ->
      case process_site(site, cfg, acc) do
        {:ok, next_acc} -> {:cont, {:ok, next_acc}}
        {:error, _reason, _details} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, acc} ->
        {:ok,
         %{
           results: Enum.reverse(acc.results),
           compile_errors: Enum.reverse(acc.compile_errors),
           state_drift_warning: acc.state_drift_warning,
           warnings: Enum.reverse(acc.warnings)
         }}

      err ->
        err
    end
  end

  defp process_site(%Site{} = site, cfg, acc) do
    case AstCache.get(cfg.ast_cache, site.file) do
      :error ->
        # Cache miss is a programmer error — but per the universal
        # partial-report shape we record it and continue with the next
        # site (so a malformed cache against one site doesn't drop the
        # whole report).
        warning = "ast_cache_miss: " <> site.file
        {:ok, %{acc | warnings: [warning | acc.warnings]}}

      {:ok, {file_ast, _source}} ->
        run_one_site(site, file_ast, cfg, acc)
    end
  end

  defp run_one_site(%Site{} = site, file_ast, cfg, acc) do
    case build_mutated_file_ast(file_ast, site) do
      {:ok, mutated_ast} ->
        # 1. Compile the mutated AST.
        case safe_compile_quoted(mutated_ast, site.file, cfg) do
          {:ok, _modules, compile_stderr} ->
            # 2. Run cited tests under the timeout/capture loop.
            outcome =
              MutationLoop.run(%{
                test_modules: cfg.test_modules,
                timeout_ms: cfg.timeout_ms,
                ex_unit: Map.get(cfg, :ex_unit, ExUnit),
                ex_unit_server: Map.get(cfg, :ex_unit_server, ExUnit.Server),
                capture_io: Map.get(cfg, :capture_io, ExUnit.CaptureIO)
              })

            # 3. Restore the original AST before anything else. A failed
            # restore aborts the pipeline (r6).
            case restore(file_ast, site.file, cfg) do
              :ok ->
                record_outcome(site, outcome, compile_stderr, acc)

              {:error, message} ->
                {:error, :unrecoverable_restore_failure,
                 %{
                   site_id: site.id,
                   file: site.file,
                   message: message
                 }}
            end

          {:error, :compile_error, message} ->
            # r5: `:compile_error` outcomes don't go in `results`; they
            # live in the parallel `compile_errors` array. We still
            # restore (no-op here because the failed compile didn't
            # replace the module).
            entry = %{
              id: site.id,
              file: site.file,
              line: site.line,
              column: site.column,
              mutator: site.mutator,
              message: message
            }

            # Defensive restore: even though the failed compile shouldn't
            # have replaced anything, calling restore here is harmless
            # and keeps state hygiene uniform.
            _ = restore(file_ast, site.file, cfg)

            {:ok, %{acc | compile_errors: [entry | acc.compile_errors]}}
        end

      {:error, :site_not_found} ->
        # Defensive — if we cannot locate the site's original node in
        # the cached AST, surface as a warning and move on. This
        # shouldn't happen with the enumerator's output, but we don't
        # want a bad site record to take down the whole runner.
        warning =
          "site_node_not_found: " <> site.id <> " in " <> site.file

        {:ok, %{acc | warnings: [warning | acc.warnings]}}
    end
  end

  # Replace the first AST node whose meta line/column matches `site.line`
  # / `site.column` AND whose value equals `site.original_ast`. The dual
  # check protects against `:erlang.phash2`-style hash collisions if a
  # file has two identical sub-trees on the same line.
  defp build_mutated_file_ast(file_ast, %Site{} = site) do
    {ast, replaced?} =
      Macro.prewalk(file_ast, false, fn node, replaced ->
        if not replaced and node_matches_site?(node, site) do
          {site.mutated_ast, true}
        else
          {node, replaced}
        end
      end)

    if replaced? do
      {:ok, ast}
    else
      {:error, :site_not_found}
    end
  end

  defp node_matches_site?({_kind, meta, _args} = node, %Site{line: line, column: column} = site)
       when is_list(meta) do
    Keyword.get(meta, :line) == line and
      Keyword.get(meta, :column) == column and
      node == site.original_ast
  end

  defp node_matches_site?(_, _), do: false

  # ---------------------------------------------------------------------------
  # Compile + restore (r6, r11)
  # ---------------------------------------------------------------------------

  defp safe_compile_quoted(ast, file, cfg) do
    {compiler_mod, compiler_fun} = Map.get(cfg, :compiler, {Code, :compile_quoted})
    capture_io = Map.get(cfg, :capture_io, ExUnit.CaptureIO)

    ref = make_ref()

    stderr =
      apply(capture_io, :capture_io, [
        :stderr,
        fn ->
          try do
            result = apply(compiler_mod, compiler_fun, [ast, file])
            Process.put({__MODULE__, ref}, {:ok, result})
          rescue
            e ->
              Process.put({__MODULE__, ref}, {:error, Exception.message(e)})
          catch
            kind, value ->
              Process.put({__MODULE__, ref}, {:error, "#{kind}: #{inspect(value)}"})
          end
        end
      ])

    case Process.get({__MODULE__, ref}) do
      {:ok, modules} ->
        Process.delete({__MODULE__, ref})
        {:ok, modules, stderr}

      {:error, message} ->
        Process.delete({__MODULE__, ref})

        {:error, :compile_error,
         message <> if(stderr == "", do: "", else: "\nstderr:\n" <> stderr)}
    end
  end

  defp restore(original_ast, file, cfg) do
    case safe_compile_quoted(original_ast, file, cfg) do
      {:ok, _modules, _stderr} -> :ok
      {:error, :compile_error, message} -> {:error, message}
    end
  end

  # ---------------------------------------------------------------------------
  # Classification & taint (r4, r5, r7)
  # ---------------------------------------------------------------------------

  defp record_outcome(%Site{} = site, outcome, compile_stderr, acc) do
    {status, run_warnings, post_meta} = classify(outcome, compile_stderr)

    delta = MutationLoop.snapshot_delta(post_meta.snapshot_before, post_meta.snapshot_after)
    grew? = MutationLoop.snapshot_grew?(delta)

    tainted_now = acc.tainted

    snapshot_warning =
      if grew? do
        [snapshot_warning(site, delta)]
      else
        []
      end

    next_tainted = tainted_now or grew? or status == :timeout

    result = %{
      id: site.id,
      file: site.file,
      line: site.line,
      column: site.column,
      mutator: site.mutator,
      original_ast: site.original_ast,
      mutated_ast: site.mutated_ast,
      status: status,
      tainted_predecessors: tainted_now,
      warnings: run_warnings
    }

    {:ok,
     %{
       acc
       | results: [result | acc.results],
         warnings: snapshot_warning ++ acc.warnings,
         tainted: next_tainted
     }}
  end

  # Three input shapes from MutationLoop.run/1, mapped onto the five
  # outcomes from r5 (minus `:compile_error`, which never reaches here).
  defp classify({:completed, exunit_result, meta}, compile_stderr) do
    status =
      cond do
        not is_map(exunit_result) -> :error
        Map.get(exunit_result, :failures, 0) > 0 -> :killed
        true -> :survived
      end

    warnings = compose_warnings([compile_stderr, meta.stderr])
    {status, warnings, meta}
  end

  defp classify({:timeout, meta}, compile_stderr) do
    warnings = compose_warnings([compile_stderr, meta.stderr, "timeout"])
    {:timeout, warnings, meta}
  end

  defp classify({:error, reason, meta}, compile_stderr) do
    warnings = compose_warnings([compile_stderr, meta.stderr, "error: " <> inspect(reason)])
    {:error, warnings, meta}
  end

  defp compose_warnings(parts) do
    parts
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp snapshot_warning(%Site{} = site, delta) do
    pieces =
      [
        if(delta.processes > 0, do: "processes+#{delta.processes}"),
        if(delta.ets > 0, do: "ets+#{delta.ets}"),
        if(delta.persistent_terms > 0, do: "persistent_term+#{delta.persistent_terms}")
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(", ")

    "state_leak after site " <>
      site.id <>
      ": " <>
      pieces <>
      " — subsequent results carry tainted_predecessors: true"
  end

  # ---------------------------------------------------------------------------
  # Input normalisation
  # ---------------------------------------------------------------------------

  defp normalise(
         %{
           seed: seed,
           timeout_ms: timeout_ms,
           test_filter: %TestFilter{},
           ast_cache: ast_cache,
           sites: sites,
           scope_records: scope_records,
           test_modules: test_modules
         } = cfg
       )
       when is_integer(seed) and seed >= 0 and is_integer(timeout_ms) and timeout_ms > 0 and
              is_map(ast_cache) and is_list(sites) and is_list(scope_records) and
              is_list(test_modules) do
    {:ok, cfg}
  end

  defp normalise(_), do: {:error, :invalid_input, %{message: "invalid MutationRunner input"}}
end
