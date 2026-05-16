defmodule MutagenEx.BeamCache do
  @moduledoc """
  Per-run `.beam` snapshot store for `MutagenEx.MutationRunner`.

  Per [`mutagen.decision.per_run_beam_cache`](../../.spec/decisions/per_run_beam_cache.md),
  this module is **stateless**: it operates on an ETS table whose lifetime
  is owned by `MutationRunner.run/1`. The table is created at the start of
  `run/1` and deleted in the `after` clause; there is no GenServer, no
  supervisor child, and no global state.

  The table holds one entry per scoped module:

      {module(), beam_filename :: charlist(), binary :: binary()}

  Inserted via `:ets.insert_new/2` so a snapshot pre-pass that runs
  concurrently with the per-site loop cannot accidentally overwrite an
  existing entry — `insert_new/2` is the canonical TOCTOU-free guard.

  ## Interaction shape

  The runner threads two pieces of state through `cfg`:

    * `cfg.beam_cache_table` — the per-run ETS table reference. Created
      once per `run/1` call, opened with
      `:ets.new(:beam_cache, [:set, :public, read_concurrency: true])`.
      `:public` access is required because per-site tasks spawned under
      `Task.Supervisor.async_stream_nolink/4` perform restore from worker
      processes that are not the table's owner.
    * `cfg.code_server` — a module implementing
      `MutagenEx.Test.CodeServerFacade`. Production callers default to
      `MutagenEx.Test.CodeServer` (delegates to `:code`); tests inject a
      recording stub.

  ## Snapshot ordering invariant

  `snapshot/3` MUST run AFTER `:cover.compile_directory/1` has
  instrumented the scoped modules. The runner's pre-pass executes in
  `MutationRunner.run/1` after `CoverageRunner` has already returned, so
  the binary captured here is the cover-instrumented binary. Restoring
  from this snapshot therefore preserves coverage instrumentation across
  the per-site mutation cycle. If the snapshot were taken before cover
  instrumented, restore would swap in the uninstrumented binary and the
  next site's coverage analysis would report nothing for that module.

  ## Restore semantics

  `restore/3` is the hot path called once per per-site cycle (and once on
  the `:compile_error` defensive branch). It assumes the snapshot
  pre-pass has populated the table; a missing entry is a programmer
  error and surfaces as `{:error, :not_snapshotted, module}`.

  Successful restore returns `{:ok, module}`. Restore failure (the
  `code_server` returned `{:error, reason}`) returns `{:error, reason}`
  so the caller can fold the result into `MutationRunner`'s existing
  restore-failure surfacing path
  (`{:error, :unrecoverable_restore_failure, ...}`).

  There is no `Code.compile_quoted/2` call in this module. The restore
  contract is "swap the cached binary back via `:code.load_binary/3`";
  the AST never participates.
  """

  @typedoc "Per-run ETS table identifier returned by `:ets.new/2`."
  @type table :: :ets.tab()

  @typedoc "Snapshot entry stored in the table."
  @type entry :: {module(), charlist(), binary()}

  @typedoc "Reasons `restore/3` can fail."
  @type restore_error ::
          {:not_snapshotted, module()}
          | {:code_server, term()}

  @doc """
  Open a new per-run ETS table with the documented options.

  This helper exists so the runner's `run/1` and tests both use exactly
  one option list. Returns the table reference, which the caller passes
  through `cfg.beam_cache_table`.
  """
  @spec new() :: table()
  def new do
    :ets.new(:beam_cache, [:set, :public, read_concurrency: true])
  end

  @doc """
  Delete the per-run ETS table.

  Called from `MutationRunner.run/1`'s `try/after` so the table is
  cleaned up on every exit path (success, `{:error, _, _}` return,
  raise/throw/exit). Safe to call with a nonexistent table (a defensive
  `:ets.info/1` check guards against double-delete in the
  `try/after` after a clean tear-down).
  """
  @spec delete(table()) :: :ok
  def delete(table) do
    case :ets.info(table) do
      :undefined ->
        :ok

      _ ->
        _ = :ets.delete(table)
        :ok
    end
  end

  @doc """
  Capture `module`'s current `.beam` and store it in `table`.

  Idempotent: a second call with the same module is a no-op. The
  underlying `:ets.insert_new/2` returns `false` on the second call;
  this function normalises both outcomes to `:ok` so callers do not
  need to distinguish first-touch from repeated-touch.

  Returns `{:error, :unavailable}` when the `code_server` returns
  `:error` for `module` — this indicates the module is not loaded or
  has no `.beam` accessible to the code server. The pre-pass should
  not encounter this for modules in the scope set (they are by
  definition compiled and loaded), but the error is surfaced rather
  than silently absorbed so the caller can decide whether to abort or
  continue.
  """
  @spec snapshot(table(), module(), module()) :: :ok | {:error, :unavailable}
  def snapshot(table, module, code_server)
      when is_atom(module) and is_atom(code_server) do
    case code_server.get_object_code(module) do
      :error ->
        {:error, :unavailable}

      {^module, binary, filename} when is_binary(binary) and is_list(filename) ->
        _ = :ets.insert_new(table, {module, filename, binary})
        :ok
    end
  end

  @doc """
  Look up `module`'s snapshot in `table` and reload it via
  `code_server.load_binary/3`.

  Returns:

    * `{:ok, module}` on success.
    * `{:error, {:not_snapshotted, module}}` when the table has no
      entry for `module` — a programmer error since the pre-pass is
      contracted to populate every scoped module before any site
      runs.
    * `{:error, {:code_server, reason}}` when the `code_server`
      returned `{:error, reason}` from `load_binary/3`. The runner
      threads this through `restore/3`'s contract so the existing
      `:unrecoverable_restore_failure` surfacing path lights up.

  The returned `{:ok, module}` tuple matches `:code.load_binary/3`'s
  success shape so callers can pattern-match either against this
  function's result or the underlying call.
  """
  @spec restore(table(), module(), module()) ::
          {:ok, module()} | {:error, restore_error()}
  def restore(table, module, code_server)
      when is_atom(module) and is_atom(code_server) do
    case :ets.lookup(table, module) do
      [] ->
        {:error, {:not_snapshotted, module}}

      [{^module, filename, binary}] ->
        case code_server.load_binary(module, filename, binary) do
          {:module, ^module} -> {:ok, module}
          {:error, reason} -> {:error, {:code_server, reason}}
        end
    end
  end
end
