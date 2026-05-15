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
            # r6 + r12: span the loaded-mutation window through
            # `with_restore/4`. Any raise/throw/exit that escapes the
            # closure triggers `safe_restore/3` before re-propagation;
            # a clean closure return still routes through `restore/3`
            # and surfaces failure as `:unrecoverable_restore_failure`.
            case with_restore(file_ast, site, cfg, fn ->
                   outcome =
                     MutationLoop.run(%{
                       test_modules: cfg.test_modules,
                       timeout_ms: cfg.timeout_ms,
                       ex_unit: Map.get(cfg, :ex_unit, MutagenEx.Test.ExUnit),
                       ex_unit_server:
                         Map.get(cfg, :ex_unit_server, MutagenEx.Test.ExUnitServer),
                       capture_io: Map.get(cfg, :capture_io, MutagenEx.Test.CaptureIo),
                       cancel_grace_ms: Map.get(cfg, :cancel_grace_ms, 100)
                     })

                   # If MutationLoop had to brutal-kill the task to honour
                   # the wall-clock budget, the task may have been mid-flight
                   # inside `:code.load_binary/3`, leaving the Code.Server
                   # holding an orphaned per-module load lock. Purge before
                   # restore re-loads. Safe on non-timeout paths too.
                   # See `mutagen.decision.timeout_handling`.
                   settle_code_server!(site, cfg, outcome)
                   outcome
                 end) do
              {:ok, outcome} ->
                record_outcome(site, outcome, compile_stderr, acc)

              {:error, :restore_failed, message} ->
                {:error, :unrecoverable_restore_failure,
                 %{
                   site_id: site.id,
                   file: site.file,
                   message: message
                 }}
            end

          {:error, :compile_error, message} ->
            # r5: `:compile_error` outcomes don't go in `results`; they
            # live in the parallel `compile_errors` array. The failed
            # compile shouldn't have replaced the module, but we still
            # call restore defensively to keep state hygiene uniform.
            # Per r6, restore failure on this branch is also abort-worthy
            # — surface it instead of swallowing (bw mutagen-wrd.17 / F27).
            entry = %{
              id: site.id,
              file: site.file,
              line: site.line,
              column: site.column,
              mutator: site.mutator,
              message: message
            }

            case restore(file_ast, site.file, cfg) do
              :ok ->
                {:ok, %{acc | compile_errors: [entry | acc.compile_errors]}}

              {:error, restore_msg} ->
                {:error, :unrecoverable_restore_failure,
                 %{
                   site_id: site.id,
                   file: site.file,
                   message:
                     "restore failed on :compile_error branch: " <>
                       restore_msg <>
                       " (original :compile_error: " <> message <> ")"
                 }}
            end
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
      if is_atom(form), do: {form, new_ambient, false}, else: walk_bare(form, new_ambient, false, site)

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
        {:error, :compile_error,
         message <> if(stderr == "", do: "", else: "\nstderr:\n" <> stderr)}
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
