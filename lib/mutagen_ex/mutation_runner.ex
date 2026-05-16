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
      structure owned by `MutagenEx.MutationRunner.MutationLoop`. The
      timeout uses the two-phase cooperative-cancellation path
      documented in `mutagen.decision.timeout_handling` (trappable
      `:shutdown` first, brutal_kill only as escalation). Timed-out
      sites are classified `:timeout` and the following site carries
      `tainted_predecessors: true`. After a `:timeout`, before
      restore, the runner calls `:code.purge/1` on the site's scoped
      modules to release any orphaned Code.Server load lock left by
      a brutal-killed task — the per-mutation hardening that
      bw mutagen-wrd.13 fixed.
    * **r5** — exactly five outcomes: `:killed`, `:survived`, `:timeout`,
      `:compile_error`, `:error`. `:compile_error` does not count toward
      the kill-rate denominator.
    * **r6** — after every per-site run, the original module is restored
      via `Code.compile_quoted(cached_ast, file)`. On restore failure the
      runner aborts with `{:error, :unrecoverable_restore_failure, ...}`.
    * **r12** — a raise, throw, or exit propagating out of the
      loaded-mutation window (from successful compile of the mutated
      AST through the test run and `:code.purge/1` settle) triggers
      restore before re-propagation. The original kind/value/stacktrace
      surfaces to the caller; restore failure during such propagation
      is best-effort and never masks the original cause. Implemented
      via `with_restore/4`, mirroring
      `MutagenEx.CoverageRunner`'s `with_cover_lifecycle/2`.
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

    * `:ex_unit` — module implementing `MutagenEx.Test.ExUnitFacade`.
      Default `MutagenEx.Test.ExUnit`. Passed through to `MutationLoop`.
    * `:ex_unit_server` — module implementing
      `MutagenEx.Test.ExUnitServerFacade`. Default
      `MutagenEx.Test.ExUnitServer`. Passed through to `MutationLoop`.
    * `:capture_io` — module implementing
      `MutagenEx.Test.CaptureIoFacade`. Default
      `MutagenEx.Test.CaptureIo`. Used by both the swap-compile capture
      around `Code.compile_quoted/2` and the per-site `MutationLoop`
      stderr capture.
    * `:compiler` — module implementing `MutagenEx.Test.CompilerFacade`,
      OR a legacy `{module, function}` tuple for back-compat with the
      pre-bw mutagen-wrd.24 stubs. Default `MutagenEx.Test.Compiler`.
      The legacy tuple shape is honored so existing test stubs that
      pass `{CompilerStub, :compile_quoted}` keep working.
    * `:cancel_grace_ms` — `non_neg_integer`. Grace window the
      cooperative-cancellation phase waits before escalating to
      brutal_kill on a timeout. Default `100`. Set to `0` in tests
      that need to exercise the brutal-only path. Passed through to
      `MutationLoop`.
    * `:code_purge` — `(module -> any)`. Test seam for the post-
      `:timeout` Code.Server settle pass. Default `&:code.purge/1`.
    * `:max_concurrency` — `pos_integer | nil`. Cap on the number of
      per-site tasks `Task.Supervisor.async_stream_nolink/4` will spawn
      in parallel. `nil` resolves to `1` (fully-serial, v1.0-equivalent
      execution) — this is also the Mix-task default when the user
      does not pass `--max-concurrency`. `N > 1` is the explicit
      opt-in path for callers with collision-free input. Regardless
      of value, results are collected in input order (the
      `async_stream` `:ordered` default) so the JSON document is
      byte-identical to the serial-equivalent run on deterministic
      scopes — taint, warnings, and per-site classification all fold
      sequentially over the ordered result list. See
      `mutagen.mutation_pipeline.r15`.
    * `:task_sup` — `atom | pid`. The `Task.Supervisor` the per-site
      tasks run under. Default `MutagenEx.TaskSup`. Tests can pass a
      one-off supervisor pid for isolation.
    * `:on_site_completed` — `(result_or_compile_error -> :ok)`. Called
      once per site as the result becomes available (in input order),
      before the runner accumulates it. This is the streaming-NDJSON
      seam: the Mix task wires this to emit one wire-shape JSON line
      per site. The runner only invokes it; it does no I/O itself
      (`mutagen.json_schema.r11`).

  ## Output shape

  `{:ok, %{results: [...], compile_errors: [...], state_drift_warning: %{...}, warnings: [...]}}`
  on full pipeline. `{:error, reason, details}` on `:self_mutation_refused`
  or `:unrecoverable_restore_failure`.
  """

  alias MutagenEx.Ast
  alias MutagenEx.AstCache
  alias MutagenEx.MutationEnumerator.Site
  alias MutagenEx.MutationRunner.MutationLoop
  alias MutagenEx.ScopeResolver.Scope
  alias MutagenEx.TestSelector.TestFilter

  @behaviour MutagenEx.Pipeline.MutationFacade

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
          warnings: [String.t()],
          end_line: pos_integer() | nil,
          end_column: pos_integer() | nil,
          source_text: String.t() | nil
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
  @impl MutagenEx.Pipeline.MutationFacade
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
    ex_unit = Map.get(cfg, :ex_unit, MutagenEx.Test.ExUnit)

    ex_unit.configure(
      max_cases: 1,
      seed: cfg.seed,
      include: cfg.test_filter.include,
      exclude: cfg.test_filter.exclude
    )

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
    case Ast.find_module_body(ast, Atom.to_string(target_mod)) do
      :not_found ->
        []

      {:ok, body} ->
        {_, list} =
          Macro.prewalk(body, [], fn
            {:use, _meta, [used | _rest]} = node, acc ->
              case Ast.alias_to_module(used) do
                nil -> {node, acc}
                mod -> {node, [mod | acc]}
              end

            node, acc ->
              {node, acc}
          end)

        list |> Enum.reverse() |> Enum.uniq()
    end
  end

  # `alias_to_module/1` and `find_module_body/2` were lifted to
  # `MutagenEx.Ast` per `mutagen.ast` (mutagen-wrd.25.2). Routes through
  # that canonical surface.

  # ---------------------------------------------------------------------------
  # Main per-site loop — async_stream over sites with ordered collection
  # ---------------------------------------------------------------------------
  #
  # The loop dispatches each site through `Task.Supervisor.async_stream_nolink/4`
  # under the configured `:task_sup` supervisor (default `MutagenEx.TaskSup`).
  # `:ordered` is `true` (the async_stream default), so the stream yields
  # site outcomes in input order regardless of which task finished first;
  # the byte-identical-output gate (`mutagen.mutation_pipeline.r15`)
  # depends on this ordering guarantee.
  #
  # Per-site classification — including taint propagation
  # (`tainted_predecessors`) — is computed in a sequential post-fold over
  # the ordered outcomes, NOT inside the task body. This is deliberate:
  # taint depends on the previous site's snapshot delta, so it must be
  # folded against the input-order stream and cannot be parallelised.
  #
  # The per-site task body covers everything that IS safely parallelisable
  # in principle: AST mutation, compile-quoted, MutationLoop.run/1
  # (timeout wrapping + ExUnit invocation), and restore. Note that ExUnit
  # globals (`ExUnit.Server`, `:cover`, the running test config) are
  # shared across tasks, so `--max-concurrency > 1` on a real ExUnit
  # backend can produce inter-site interference. The default in v1.1
  # remains `System.schedulers_online()`; consumers needing fully-serial
  # behaviour pass `--max-concurrency 1`. The byte-identical-output gate
  # is verified against the test fakes (Agent-backed `ExUnitFake`,
  # CompilerStub) which are concurrency-safe by construction.
  defp execute(cfg, drift) do
    sites = cfg.sites
    total = length(sites)
    max_concurrency = resolve_max_concurrency(cfg)
    on_site_completed = Map.get(cfg, :on_site_completed, fn _ -> :ok end)

    initial = %{
      results: [],
      compile_errors: [],
      state_drift_warning: drift,
      warnings: [],
      tainted: false,
      truncated: false
    }

    # `budget_ms` is the aggregate wall-clock budget from `--budget-ms`
    # (mutagen.cli.r13). `nil` means unbounded — the existing per-site
    # `timeout_ms` is the only cap. When budget is set, the fold checks
    # elapsed wall-clock BEFORE processing each completed-site outcome
    # and bails with `truncated: true` once the cap is hit. We don't
    # interrupt a site in flight — the per-site timeout owns that — so
    # the worst-case overshoot is one `timeout_ms`. On the serial path
    # (`max_concurrency == 1`) the outer stream is lazy, so halting
    # early also avoids dispatching subsequent sites.
    budget_ms = Map.get(cfg, :budget_ms)
    started_at = System.monotonic_time(:millisecond)

    indexed_sites = Enum.with_index(sites, 1)

    # When `max_concurrency == 1` we stay in the caller process. This:
    #   1. Preserves the v1.0 byte-identical execution path — the
    #      fold reaches exactly the same accumulator updates in
    #      exactly the same order.
    #   2. Keeps Process-dictionary-backed test stubs working without
    #      having to thread state through `Task.Supervisor`. The
    #      existing `RecordingCompiler`-style hooks (see
    #      `test/mutagen_ex/mutation_runner_raise_test.exs`) record
    #      every compile call in the caller's process dictionary; a
    #      spawned task would never see those hooks.
    #
    # When `max_concurrency > 1` we dispatch through
    # `Task.Supervisor.async_stream_nolink/4` under the configured
    # `:task_sup`. The stream's `:ordered: true` default guarantees
    # the fold sees outcomes in input order, so the byte-identical
    # contract still holds for deterministic scopes — taint,
    # warnings, and counters all fold sequentially over the ordered
    # result list.
    task_outcomes_stream =
      if max_concurrency == 1 do
        Stream.map(indexed_sites, fn {site, idx} ->
          {:ok, process_site_task(site, idx, total, cfg)}
        end)
      else
        task_sup = Map.get(cfg, :task_sup, MutagenEx.TaskSup)

        Task.Supervisor.async_stream_nolink(
          task_sup,
          indexed_sites,
          fn {site, idx} -> process_site_task(site, idx, total, cfg) end,
          max_concurrency: max_concurrency,
          ordered: true,
          # Per-site timeout is handled INSIDE `MutationLoop.run/1`; the
          # outer async_stream timeout is effectively unbounded (the
          # inner task's wall-clock budget governs). `:infinity` makes
          # it explicit that the outer stream does not impose a second
          # competing deadline.
          timeout: :infinity,
          on_timeout: :kill_task
        )
      end

    outcome =
      Enum.reduce_while(task_outcomes_stream, {:ok, initial}, fn
        {:ok, task_outcome}, {:ok, acc} ->
          # Fold the completed site's outcome FIRST (so the site that
          # crossed the budget still lands in results), then evaluate
          # the budget AFTER recording it — that decides whether to
          # short-circuit the remaining sites. The worst-case overshoot
          # is exactly one `timeout_ms` per `mutagen.cli.r13` because
          # the per-site task is not interrupted mid-flight.
          case fold_task_outcome(task_outcome, cfg, acc, on_site_completed) do
            {:cont, next_acc} ->
              if budget_exceeded?(budget_ms, started_at) do
                truncated = %{
                  next_acc
                  | warnings: [budget_truncation_warning(budget_ms) | next_acc.warnings],
                    truncated: true
                }

                {:halt, {:ok, truncated}}
              else
                {:cont, {:ok, next_acc}}
              end

            {:halt, abort} ->
              {:halt, abort}
          end

        {:exit, reason}, {:ok, _acc} ->
          # An outer task exited unexpectedly (e.g. the supervisor
          # killed it). Surface as an abort — the in-process pipeline
          # does not have a "skip this site" recovery for outer-task
          # death.
          {:halt,
           {:error, :unrecoverable_restore_failure,
            %{message: "per-site outer task exited: " <> inspect(reason)}}}
      end)

    case outcome do
      {:ok, acc} ->
        {:ok,
         %{
           results: Enum.reverse(acc.results),
           compile_errors: Enum.reverse(acc.compile_errors),
           state_drift_warning: acc.state_drift_warning,
           warnings: Enum.reverse(acc.warnings),
           truncated: Map.get(acc, :truncated, false)
         }}

      err ->
        err
    end
  end

  defp budget_exceeded?(nil, _started_at), do: false

  defp budget_exceeded?(budget_ms, started_at) when is_integer(budget_ms) do
    elapsed = System.monotonic_time(:millisecond) - started_at
    elapsed >= budget_ms
  end

  defp budget_truncation_warning(budget_ms) do
    "budget_exceeded: aggregate --budget-ms #{budget_ms} reached; " <>
      "report truncated to completed sites only"
  end

  # Resolves the per-site concurrency cap.
  #
  # The runner defaults to `1` (fully serial, in-caller-process) when
  # no value is set — the conservative, deterministic default that
  # preserves the v1.0 contract. The Mix task (`Mix.Tasks.Mutagen`)
  # mirrors this default: `Config.max_concurrency == nil` resolves to
  # `1` there too (`mix/tasks/mutagen.ex` — `config.max_concurrency
  # || 1`), so the user-facing default for `mix mutagen` is
  # `--max-concurrency 1`. Users pass `--max-concurrency N` (N > 1)
  # explicitly to opt in to parallelism. See
  # `mutagen.mutation_pipeline.r15` for the in-process pipeline
  # caveat (shared ExUnit/Code.Server/cover state) that motivates
  # default-1.
  defp resolve_max_concurrency(cfg) do
    case Map.get(cfg, :max_concurrency) do
      nil -> 1
      n when is_integer(n) and n > 0 -> n
    end
  end

  # Per-site task body. Returns a `task_outcome` tuple that the
  # sequential post-fold turns into accumulator updates. The shape is
  # always `{:ok, site, source_text, outcome, stderr}` (the happy path
  # carries `source_text` for the renderer's verbatim-source-slice;
  # see `mutagen.json_schema.r4`), `{:compile_error, site, msg}`,
  # `{:ast_miss, site}`, `{:site_not_found, site}`, or `{:abort,
  # reason, details}`; the fold decides whether to continue or halt.
  defp process_site_task(%Site{} = site, idx, total, cfg) do
    MutagenEx.Telemetry.span(
      :site,
      %{
        site_id: site.id,
        file: site.file,
        line: site.line,
        mutator: site.mutator,
        index: idx,
        total: total
      },
      fn ->
        outcome = process_site_body(site, cfg)
        stop_status = task_outcome_status(outcome)

        {outcome,
         %{
           site_id: site.id,
           file: site.file,
           line: site.line,
           mutator: site.mutator,
           index: idx,
           total: total,
           status: stop_status
         }}
      end
    )
  end

  defp task_outcome_status({:ok, _site, _src, {:completed, %{failures: f}, _meta}, _stderr})
       when is_integer(f) and f > 0,
       do: :killed

  defp task_outcome_status({:ok, _site, _src, {:completed, %{}, _meta}, _stderr}), do: :survived
  defp task_outcome_status({:ok, _site, _src, {:timeout, _meta}, _stderr}), do: :timeout
  defp task_outcome_status({:ok, _site, _src, {:error, _reason, _meta}, _stderr}), do: :error
  defp task_outcome_status({:compile_error, _site, _msg}), do: :compile_error
  defp task_outcome_status({:ast_miss, _site}), do: :compile_error
  defp task_outcome_status({:site_not_found, _site}), do: :compile_error

  defp task_outcome_status({:abort, _reason, _details}), do: :error

  defp process_site_body(%Site{} = site, cfg) do
    case AstCache.get(cfg.ast_cache, site.file) do
      :error ->
        {:ast_miss, site}

      {:ok, {file_ast, source_text}} ->
        run_one_site_task(site, file_ast, source_text, cfg)
    end
  end

  defp run_one_site_task(%Site{} = site, file_ast, source_text, cfg) do
    case build_mutated_file_ast(file_ast, site) do
      {:ok, mutated_ast} ->
        case safe_compile_quoted(mutated_ast, site.file, cfg) do
          {:ok, _modules, compile_stderr} ->
            run_within_restore(site, file_ast, source_text, compile_stderr, cfg)

          {:error, :compile_error, message} ->
            # r5: `:compile_error` outcomes don't go in `results`; they
            # live in the parallel `compile_errors` array. The failed
            # compile shouldn't have replaced the module, but we still
            # call restore defensively to keep state hygiene uniform.
            # Per r6, restore failure on this branch is also abort-worthy
            # — surface it instead of swallowing (bw mutagen-wrd.17 / F27).
            # `message` is already sanitized by safe_compile_quoted/3
            # (r10/r11 cap + redact applied there before this branch).
            case restore(file_ast, site.file, cfg) do
              :ok ->
                {:compile_error, site, message}

              {:error, restore_msg} ->
                {:abort, :unrecoverable_restore_failure,
                 %{
                   site_id: site.id,
                   file: site.file,
                   message:
                     MutagenEx.JsonReporter.Sanitizer.clean(
                       "restore failed on :compile_error branch: " <>
                         restore_msg <>
                         " (original :compile_error: " <> message <> ")"
                     )
                 }}
            end
        end

      {:error, :site_not_found} ->
        {:site_not_found, site}
    end
  end

  defp run_within_restore(%Site{} = site, file_ast, source_text, compile_stderr, cfg) do
    case with_restore(file_ast, site, cfg, fn ->
           outcome =
             MutationLoop.run(%{
               test_modules: cfg.test_modules,
               timeout_ms: cfg.timeout_ms,
               ex_unit: Map.get(cfg, :ex_unit, MutagenEx.Test.ExUnit),
               ex_unit_server: Map.get(cfg, :ex_unit_server, MutagenEx.Test.ExUnitServer),
               capture_io: Map.get(cfg, :capture_io, MutagenEx.Test.CaptureIo),
               cancel_grace_ms: Map.get(cfg, :cancel_grace_ms, 100),
               task_sup: Map.get(cfg, :task_sup, MutagenEx.TaskSup)
             })

           settle_code_server!(site, cfg, outcome)
           outcome
         end) do
      {:ok, outcome} ->
        # `source_text` is threaded through here so the post-fold can
        # add it to the result map for the renderer's verbatim slice
        # path (`mutagen.json_schema.r4`).
        {:ok, site, source_text, outcome, compile_stderr}

      {:error, :restore_failed, message} ->
        {:abort, :unrecoverable_restore_failure,
         %{
           site_id: site.id,
           file: site.file,
           message: MutagenEx.JsonReporter.Sanitizer.clean(message)
         }}
    end
  end

  # ---------------------------------------------------------------------------
  # Sequential post-fold over ordered task outcomes
  # ---------------------------------------------------------------------------
  #
  # Taint (`tainted_predecessors`) cascades over the ORDERED stream —
  # async_stream's `:ordered: true` guarantees the fold sees outcomes
  # in input order even if tasks completed out of order. The fold also
  # invokes `:on_site_completed` for each accumulated site so the Mix
  # task's NDJSON streamer emits in the same order.

  defp fold_task_outcome(
         {:ok, site, source_text, outcome, compile_stderr},
         _cfg,
         acc,
         on_site_completed
       ) do
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
      warnings: run_warnings,
      # Threaded through for the JSON renderer's verbatim-source-slice
      # path (`mutagen.json_schema.r4`). When `end_line`/`end_column`
      # are nil, the renderer falls back to aliasing `before` into
      # `before_source`; when non-nil it slices `source_text` between
      # the leftmost descendant of `original_ast` and
      # `{end_line, end_column}`.
      end_line: site.end_line,
      end_column: site.end_column,
      source_text: source_text
    }

    _ = on_site_completed.({:result, result})

    {:cont,
     %{
       acc
       | results: [result | acc.results],
         warnings: snapshot_warning ++ acc.warnings,
         tainted: next_tainted
     }}
  end

  defp fold_task_outcome({:compile_error, site, message}, _cfg, acc, on_site_completed) do
    entry = %{
      id: site.id,
      file: site.file,
      line: site.line,
      column: site.column,
      mutator: site.mutator,
      message: message
    }

    _ = on_site_completed.({:compile_error, entry})

    {:cont, %{acc | compile_errors: [entry | acc.compile_errors]}}
  end

  defp fold_task_outcome({:ast_miss, site}, _cfg, acc, _on_site_completed) do
    warning = "ast_cache_miss: " <> site.file
    {:cont, %{acc | warnings: [warning | acc.warnings]}}
  end

  defp fold_task_outcome({:site_not_found, site}, _cfg, acc, _on_site_completed) do
    warning = "site_node_not_found: " <> site.id <> " in " <> site.file
    {:cont, %{acc | warnings: [warning | acc.warnings]}}
  end

  defp fold_task_outcome({:abort, reason, details}, _cfg, _acc, _on_site_completed) do
    {:halt, {:error, reason, details}}
  end

  # Wrap a closure that operates while a mutated AST is installed as the
  # module's current code. The protected window must complete with the
  # original AST restored on every path — successful completion, runtime
  # raise/throw/exit, or restore failure.
  #
  # Per `mutagen.mutation_pipeline.r12`:
  #   - Closure return + restore success → `{:ok, result}`.
  #   - Closure return + restore failure → `{:error, :restore_failed, msg}`
  #     (the caller surfaces this as `:unrecoverable_restore_failure`).
  #   - Closure raise/throw/exit → `safe_restore/3` runs best-effort, then
  #     the original kind/value/stacktrace is re-propagated via
  #     `reraise/2` or `:erlang.raise/3`. Restore failure during
  #     propagation is intentionally swallowed inside `safe_restore/3`
  #     so it cannot mask the original cause.
  #
  # Shape mirrors `MutagenEx.CoverageRunner.with_cover_lifecycle/2`.
  defp with_restore(file_ast, %Site{} = site, cfg, fun) do
    try do
      result = fun.()

      case restore(file_ast, site.file, cfg) do
        :ok -> {:ok, result}
        {:error, message} -> {:error, :restore_failed, message}
      end
    rescue
      e ->
        _ = safe_restore(file_ast, site, cfg)
        reraise(e, __STACKTRACE__)
    catch
      kind, value ->
        _ = safe_restore(file_ast, site, cfg)
        :erlang.raise(kind, value, __STACKTRACE__)
    end
  end

  # Cleanup that never throws. Preserves the original exception inside
  # `rescue` / `catch` clauses by swallowing any failure of `restore/3`
  # itself (including raises from a misbehaving `:compiler` seam).
  defp safe_restore(file_ast, %Site{} = site, cfg) do
    try do
      restore(file_ast, site.file, cfg)
    rescue
      _ -> {:error, "safe_restore: restore raised"}
    catch
      _, _ -> {:error, "safe_restore: restore threw or exited"}
    end
  end

  # Replace the first AST node whose positional metadata matches
  # `site.line` / `site.column` AND whose value equals
  # `site.original_ast`. The dual check protects against
  # `:erlang.phash2`-style hash collisions if a file has two identical
  # sub-trees on the same line.
  #
  # Two shapes are handled (bw mutagen-wrd.16):
  #
  #   1. 3-tuple `{form, meta, args}` — the common case. The match
  #      keys directly off `meta`. Located via `Macro.prewalk/3`.
  #   2. Bare atomic literal (`0`, `1`, `-1`, `true`, `false`) — the
  #      literal mutator's bare-value clauses produce sites whose
  #      `original_ast` is the bare value. The bare node carries no
  #      metadata of its own; the enumerator attributes the site to
  #      the *parent* operator / clause-head's `:line` and `:column`.
  #      We locate these via a custom walker that threads ambient
  #      `{line, column}` downward, mirroring the enumerator's
  #      `walk_tree/6`. Run as a second pass only when shape (1)
  #      didn't find a match — keeps the happy path cheap.
  defp build_mutated_file_ast(file_ast, %Site{} = site) do
    {ast, replaced?} =
      Macro.prewalk(file_ast, false, fn node, replaced ->
        if not replaced and node_matches_site?(node, site) do
          {site.mutated_ast, true}
        else
          {node, replaced}
        end
      end)

    cond do
      replaced? ->
        {:ok, ast}

      bare_literal_site?(site) ->
        replace_bare_site(file_ast, site)

      true ->
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

  # Bare-literal sites have no metadata on the node itself; their
  # `original_ast` is a raw integer or boolean.
  defp bare_literal_site?(%Site{original_ast: v}) when is_integer(v) or is_boolean(v), do: true
  defp bare_literal_site?(_), do: false

  # Find-and-swap the bare literal whose ambient (parent) line/column
  # match site.line / site.column. Returns `{:ok, ast}` on success and
  # `{:error, :site_not_found}` otherwise.
  defp replace_bare_site(file_ast, %Site{} = site) do
    {new_ast, _ambient, replaced?} =
      walk_bare(file_ast, {nil, 1}, false, site)

    if replaced?, do: {:ok, new_ast}, else: {:error, :site_not_found}
  end

  # Pre-order walker that mirrors the enumerator's `walk_tree/6`:
  # threads `{ambient_line, ambient_column}` downward and short-circuits
  # via the `replaced?` flag once the first bare-literal match is
  # rewritten. Returns `{rewritten_node, ambient_for_next_sibling,
  # replaced?}`. The ambient returned is the input ambient — siblings
  # walk under the *parent's* ambient, not under any child's.
  defp walk_bare(node, ambient, true, _site), do: {node, ambient, true}

  defp walk_bare(node, ambient, false, %Site{} = site) do
    cond do
      bare_match?(node, ambient, site) ->
        {site.mutated_ast, ambient, true}

      true ->
        descend_bare(node, ambient, site)
    end
  end

  defp bare_match?(value, {ambient_line, ambient_column}, %Site{
         line: line,
         column: column,
         original_ast: original
       })
       when is_integer(value) or is_boolean(value) do
    ambient_line == line and ambient_column == column and value === original
  end

  defp bare_match?(_, _, _), do: false

  # Descend into structured nodes. For 3-tuples we update ambient from
  # the node's own metadata before walking children — exactly the rule
  # the enumerator uses, so the site's line/column resolves identically
  # at runner-time.
  defp descend_bare({form, meta, args}, ambient, site) when is_list(meta) do
    new_ambient = update_ambient_runner(meta, ambient)

    {form2, _amb, replaced_form?} =
      if is_atom(form),
        do: {form, new_ambient, false},
        else: walk_bare(form, new_ambient, false, site)

    case args do
      children when is_list(children) ->
        {children2, replaced_children?} =
          walk_bare_list(children, new_ambient, replaced_form?, site)

        {{form2, meta, children2}, ambient, replaced_children?}

      _ ->
        {{form2, meta, args}, ambient, replaced_form?}
    end
  end

  defp descend_bare({a, b}, ambient, site) do
    {a2, _amb, replaced_a?} = walk_bare(a, ambient, false, site)
    {b2, _amb2, replaced_b?} = walk_bare(b, ambient, replaced_a?, site)
    {{a2, b2}, ambient, replaced_a? or replaced_b?}
  end

  defp descend_bare(list, ambient, site) when is_list(list) do
    {list2, replaced?} = walk_bare_list(list, ambient, false, site)
    {list2, ambient, replaced?}
  end

  defp descend_bare(other, ambient, _site), do: {other, ambient, false}

  defp walk_bare_list(children, ambient, replaced_in?, site) do
    {rev, final_replaced?} =
      Enum.reduce(children, {[], replaced_in?}, fn child, {acc, replaced_acc?} ->
        {new_child, _amb, replaced_now?} = walk_bare(child, ambient, replaced_acc?, site)
        {[new_child | acc], replaced_now? or replaced_acc?}
      end)

    {Enum.reverse(rev), final_replaced?}
  end

  defp update_ambient_runner(meta, {prior_line, prior_column}) when is_list(meta) do
    line = Keyword.get(meta, :line, prior_line)
    column = Keyword.get(meta, :column, prior_column)
    {line, column}
  end

  # ---------------------------------------------------------------------------
  # Code.Server settle (r4 hardening — `mutagen.decision.timeout_handling`)
  # ---------------------------------------------------------------------------

  # After a per-site mutation run that ended in `:timeout`, the inner
  # task may have been brutal-killed mid-flight inside `:code.load_binary/3`
  # (cover-recompile racing the mutation cycle). The Code.Server can be
  # left holding an orphaned per-module load lock; the next site's
  # compile-and-load cycle deadlocks waiting on it.
  #
  # Mitigation: call `:code.purge/1` on every scope record whose file
  # matches the just-mutated site. `:code.purge/1` is documented to
  # "remove the old code for the module" and, in OTP's current
  # implementation, also clears the code_server's tracking state for
  # that module — releasing the orphaned lock. Modules with no old
  # revision are a no-op.
  #
  # We only purge after a `:timeout`-classified outcome to keep the
  # happy-path cycle cheap. Graceful cancels and normal completions
  # do not trigger purge.
  #
  # `code_purge` is configurable for tests: pass `cfg.code_purge :: (module -> any)`.
  defp settle_code_server!(%Site{} = site, cfg, outcome) do
    needs_settle? =
      case outcome do
        {:timeout, %{cancel_mode: :brutal}} -> true
        {:timeout, _} -> true
        _ -> false
      end

    if needs_settle? do
      purge_fun = Map.get(cfg, :code_purge, &:code.purge/1)

      modules_for_file =
        cfg.scope_records
        |> Enum.filter(fn %Scope{file: f} -> f == site.file end)
        |> Enum.map(& &1.module)

      Enum.each(modules_for_file, fn mod ->
        try do
          purge_fun.(mod)
        rescue
          _ -> :ok
        catch
          _, _ -> :ok
        end
      end)
    end

    :ok
  end

  # ---------------------------------------------------------------------------
  # Compile + restore (r6, r11)
  # ---------------------------------------------------------------------------

  defp safe_compile_quoted(ast, file, cfg) do
    compile_fn = compiler_call(cfg)
    capture_io = Map.get(cfg, :capture_io, MutagenEx.Test.CaptureIo)

    # `with_io/2` returns `{closure_result, captured_io}` synchronously —
    # no process-dictionary smuggle needed. Per `mutagen-wrd.23` this
    # replaces the older `make_ref/Process.put/Process.get` pattern that
    # relied on the (undocumented) fact that `capture_io/2` runs its
    # closure in the calling process.
    {body_result, stderr} =
      capture_io.with_io(:stderr, fn ->
        try do
          {:ok, compile_fn.(ast, file)}
        rescue
          e -> {:error, Exception.message(e)}
        catch
          kind, value -> {:error, "#{kind}: #{inspect(value)}"}
        end
      end)

    case body_result do
      {:ok, modules} ->
        {:ok, modules, stderr}

      {:error, message} ->
        # mutagen.json_schema.r10/r11: bound + redact the compile-error
        # body. Stderr can be multi-MB for some warning-heavy mutations,
        # and exception messages can echo source slices.
        sanitized =
          MutagenEx.JsonReporter.Sanitizer.clean(
            message <> if(stderr == "", do: "", else: "\nstderr:\n" <> stderr)
          )

        {:error, :compile_error, sanitized}
    end
  end

  # Resolve the compile-quoted call. Production / new-shape callers pass
  # a module atom implementing `MutagenEx.Test.CompilerFacade`. Legacy
  # callers (pre-bw mutagen-wrd.24) pass a `{module, function}` tuple;
  # that shape is preserved so existing test stubs continue to work.
  # Returns a 2-arity function `(ast, file -> [{module, binary}])`.
  defp compiler_call(cfg) do
    case Map.get(cfg, :compiler, MutagenEx.Test.Compiler) do
      mod when is_atom(mod) ->
        fn ast, file -> mod.compile_quoted(ast, file) end

      {mod, fun} when is_atom(mod) and is_atom(fun) ->
        fn ast, file -> apply(mod, fun, [ast, file]) end
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
    # mutagen.json_schema.r10/r11: warnings carry compile-stderr and
    # in-runner stderr that can include source slices + secrets. Bound
    # each part to the 4 KiB cap and apply the configured redactions
    # before they hit results[i].warnings.
    parts
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&MutagenEx.JsonReporter.Sanitizer.clean/1)
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
