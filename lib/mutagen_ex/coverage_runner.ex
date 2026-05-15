defmodule MutagenEx.CoverageRunner do
  @moduledoc """
  Runs the cited test suite once under `:cover` to determine which source
  lines those tests exercise.

  Contract: [`mutagen.coverage`](../../.spec/specs/coverage.spec.md) r1-r5,
  r7.

  ## Lifecycle invariants

    * **r1 — refuse if cover already running.** If
      `Process.whereis(:cover_server)` returns a non-nil pid before we
      start, the runner aborts with `{:error, :cover_already_running, ...}`
      without calling `:cover.compile_*` or `ExUnit.run/0`.
    * **r2 — cover stopped after return.** Whether `run/1` succeeds or
      errors, `:cover.stop/0` is invoked at least once. The call is wrapped
      in `try/rescue` so repeated stops are idempotent.
    * **r3 — modules de-instrumented.** After `:cover.stop/0`,
      `:code.which/1` for every cover-instrumented module returns a real
      `.beam` path (or `:non_existing`) rather than `:cover_compiled`.
    * **r4 — forced ExUnit configuration.** `ExUnit.configure(max_cases: 1,
      seed: cfg.seed)` runs **before** any test. There is no `--parallel`
      knob in v1.
    * **r5 — scope-filtered output.** The returned `covered_lines` map is
      keyed by relative file path and contains entries only for files that
      back the modules in `cfg.in_scope_modules`.
    * **r7 — no disk writes.** `run/1` does not modify any file on disk.

  ## Input shape

  `run/1` takes a map with at least:

    * `:seed` — non-negative integer, the ExUnit seed.
    * `:in_scope_modules` — list of `{module, source_file}` tuples. The
      `source_file` is a relative path (the same string scope records
      carry); it's used both as the cover-compile target (we locate the
      module's `.beam` and instrument it) and as the result key.
    * `:test_filter` — `%MutagenEx.TestSelector.TestFilter{}`. Drives the
      ExUnit include/exclude/files configuration.

  Optional:

    * `:ex_unit` — module implementing `MutagenEx.Test.ExUnitFacade`.
      Defaults to `MutagenEx.Test.ExUnit`, which delegates to the real
      `ExUnit`. The seam exists so the failure-path tests can assert the
      runner aborts **before** any `ExUnit` call.
    * `:cover` — module implementing `MutagenEx.Test.CoverFacade`.
      Defaults to `MutagenEx.Test.Cover`, which delegates to Erlang's
      `:cover` module. Existence solely as a test seam.
    * `:test_loader` — `(path :: String.t() -> any())` — overrides
      `Code.require_file/1`. Tests use this to track that test files are
      loaded once, not per-phase.

  ## S2 spike findings carried forward

  * `:cover` lives under OTP's `lib/tools-*/ebin` and is not on the default
    Mix code path. `ensure_cover_loadable/0` does the same path-append the
    C1 spike did. This is shared with the C1 fixture; production code paths
    don't always have `:cover` loaded.
  * `:cover.compile_beam/1` requires the `Dbgi` chunk. Mix's `test` env
    defaults to `debug_info: true`, so project `.beam` files already carry
    it. We do not flip `Code.compiler_options/1`.
  """

  alias MutagenEx.TestSelector.TestFilter

  @behaviour MutagenEx.Pipeline.CoverageFacade

  @typedoc "Reasons the runner can return as the second element of `{:error, _, _}`."
  @type error_reason ::
          :cover_already_running
          | :cover_module_unavailable
          | :module_beam_missing
          | :cover_compile_failed
          | :ex_unit_run_failed
          | :test_file_load_failed
          | :invalid_input

  @typedoc "Successful return."
  @type ok_result :: %{
          covered_lines: %{optional(String.t()) => MapSet.t(pos_integer())},
          instrumented_modules: [module()]
        }

  @doc """
  Run the cited tests under `:cover` and return per-file covered line sets.

  See module doc for input/output shape and lifecycle invariants.
  """
  @impl MutagenEx.Pipeline.CoverageFacade
  @spec run(map()) :: {:ok, ok_result()} | {:error, error_reason(), map()}
  def run(input) when is_map(input) do
    with {:ok, normalised} <- normalise(input) do
      do_run(normalised)
    end
  end

  # ---------------------------------------------------------------------------
  # Top-level state machine
  # ---------------------------------------------------------------------------

  defp do_run(cfg) do
    case cover_already_running?(cfg) do
      true ->
        # r1: refuse before any compile / test run.
        {:error, :cover_already_running,
         %{
           message:
             ":cover_server is already registered. " <>
               "MutagenEx.TaskSup is the documented singleton owner of " <>
               ":cover_server and ExUnit.Server during a MutagenEx mutation " <>
               "cycle; a competing session is refused to prevent state " <>
               "corruption. See .spec/decisions/supervision_tree.md."
         }}

      false ->
        with_cover_lifecycle(cfg, fn ->
          run_under_cover(cfg)
        end)
    end
  end

  # r2: ALL exits — success, error, and crash — flow through `:cover.stop/0`.
  # The `try/rescue` makes the call idempotent: repeated stops or a stop
  # against a never-started cover both return cleanly. The block re-raises
  # so a genuinely unrecoverable error still surfaces to the caller.
  defp with_cover_lifecycle(cfg, fun) do
    try do
      result = fun.()
      safe_cover_stop(cfg)
      result
    rescue
      e ->
        safe_cover_stop(cfg)
        reraise(e, __STACKTRACE__)
    catch
      kind, value ->
        safe_cover_stop(cfg)
        :erlang.raise(kind, value, __STACKTRACE__)
    end
  end

  defp run_under_cover(cfg) do
    with :ok <- ensure_cover_loadable(cfg),
         :ok <- start_cover(cfg),
         {:ok, instrumented} <- cover_compile_modules(cfg),
         :ok <- configure_exunit(cfg),
         :ok <- load_test_files(cfg),
         {:ok, _exunit_result} <- run_exunit(cfg),
         {:ok, covered} <- gather_covered_lines(cfg, instrumented) do
      {:ok,
       %{
         covered_lines: covered,
         instrumented_modules: instrumented
       }}
    end
  end

  # ---------------------------------------------------------------------------
  # Lifecycle steps
  # ---------------------------------------------------------------------------

  defp cover_already_running?(_cfg) do
    case Process.whereis(:cover_server) do
      nil -> false
      pid when is_pid(pid) -> true
    end
  end

  # `:cover` ships in OTP's `tools` application which is loaded on demand.
  # The S2 spike confirmed `:code.lib_dir(:tools)` returns `{:error,
  # :bad_name}` when tools hasn't been loaded yet; we resolve via the OTP
  # root + wildcard, exactly as the spike does.
  #
  # `:cover` is the *underlying* Erlang module, distinct from the facade
  # module (`MutagenEx.Test.Cover` by default). The default cover facade
  # delegates to `:cover`, so we must ensure that atom is loadable. Tests
  # that swap in their own cover facade do not need this step — their
  # fake module is always loaded under the test app's compile path.
  defp ensure_cover_loadable(cfg) do
    cover_facade = Map.get(cfg, :cover, MutagenEx.Test.Cover)

    if cover_facade == MutagenEx.Test.Cover do
      ensure_underlying_cover_loaded()
    else
      :ok
    end
  end

  defp ensure_underlying_cover_loaded do
    case Code.ensure_loaded(:cover) do
      {:module, :cover} ->
        :ok

      _ ->
        case locate_tools_ebin() do
          {:ok, path} ->
            Code.append_path(path)

            case Code.ensure_loaded(:cover) do
              {:module, :cover} ->
                :ok

              other ->
                {:error, :cover_module_unavailable,
                 %{
                   message: "could not load :cover from #{inspect(path)}: #{inspect(other)}"
                 }}
            end

          :not_found ->
            {:error, :cover_module_unavailable,
             %{
               message: "could not locate OTP tools-*/ebin under :code.root_dir/0"
             }}
        end
    end
  end

  defp locate_tools_ebin do
    root = List.to_string(:code.root_dir())

    case Path.wildcard(Path.join(root, "lib/tools-*/ebin")) do
      [path | _] -> {:ok, path}
      [] -> :not_found
    end
  end

  defp start_cover(cfg) do
    cover_mod = Map.get(cfg, :cover, MutagenEx.Test.Cover)

    case cover_mod.start() do
      {:ok, _pid} ->
        :ok

      {:error, {:already_started, _pid}} ->
        :ok

      other ->
        {:error, :cover_compile_failed, %{message: "cover.start failed: #{inspect(other)}"}}
    end
  end

  defp safe_cover_stop(cfg) do
    cover_mod = Map.get(cfg, :cover, MutagenEx.Test.Cover)

    try do
      cover_mod.stop()
    rescue
      _ -> :ok
    catch
      _, _ -> :ok
    end

    :ok
  end

  defp cover_compile_modules(cfg) do
    cover_mod = Map.get(cfg, :cover, MutagenEx.Test.Cover)

    cfg.in_scope_modules
    |> Enum.reduce_while({:ok, []}, fn {module, file}, {:ok, acc} ->
      case beam_path_for(module) do
        {:ok, path} ->
          # `:cover.compile_beam/1` returns `{:ok, mod}` on success and
          # `{:error, reason}` on failure. We accept any `{:ok, _}` return
          # because cover guarantees the instrumentation matches the .beam
          # we pointed it at.
          case cover_mod.compile_beam(path) do
            {:ok, _instrumented_mod} ->
              {:cont, {:ok, [{module, file} | acc]}}

            {:error, reason} ->
              {:halt,
               {:error, :cover_compile_failed,
                %{
                  module: module,
                  file: file,
                  message: "cover.compile_beam(#{inspect(module)}) failed: #{inspect(reason)}"
                }}}

            other ->
              {:halt,
               {:error, :cover_compile_failed,
                %{
                  module: module,
                  file: file,
                  message:
                    "cover.compile_beam(#{inspect(module)}) returned unexpected: #{inspect(other)}"
                }}}
          end

        :error ->
          {:halt,
           {:error, :module_beam_missing,
            %{
              module: module,
              file: file,
              message:
                "no .beam file located for #{inspect(module)} via :code.which/1; " <>
                  "module must be loaded before coverage starts"
            }}}
      end
    end)
    |> case do
      {:ok, list} -> {:ok, Enum.reverse(list)}
      err -> err
    end
  end

  defp beam_path_for(module) do
    case :code.which(module) do
      path when is_list(path) -> {:ok, path}
      _ -> :error
    end
  end

  # r4: forced ExUnit.configure(max_cases: 1, seed: seed). The async flag is
  # ignored — modules can still be `async: true`; max_cases: 1 collapses
  # them to serial execution per mutagen.decision.serial_execution_and_seed.
  defp configure_exunit(cfg) do
    ex_unit = Map.get(cfg, :ex_unit, MutagenEx.Test.ExUnit)

    ex_unit.configure([max_cases: 1, seed: cfg.seed] ++ test_filter_options(cfg.test_filter))

    :ok
  end

  defp test_filter_options(%TestFilter{include: include, exclude: exclude}) do
    [include: include, exclude: exclude]
  end

  # The runner loads test files exactly once; mutation_pipeline.r10
  # documents this. We expose a `:test_loader` seam so the failure-mode
  # tests can assert load count without touching disk. Default uses
  # `Code.require_file/1`, which itself caches by path — calling it twice
  # is a no-op.
  defp load_test_files(cfg) do
    loader = Map.get(cfg, :test_loader, &Code.require_file/1)

    Enum.reduce_while(cfg.test_filter.files, :ok, fn file, :ok ->
      try do
        _ = loader.(file)
        {:cont, :ok}
      rescue
        e ->
          {:halt,
           {:error, :test_file_load_failed,
            %{
              file: file,
              message: "could not load test file #{inspect(file)}: #{Exception.message(e)}"
            }}}
      end
    end)
  end

  defp run_exunit(cfg) do
    ex_unit = Map.get(cfg, :ex_unit, MutagenEx.Test.ExUnit)

    try do
      result = ex_unit.run()
      {:ok, result}
    rescue
      e ->
        {:error, :ex_unit_run_failed,
         %{
           message: "ExUnit.run/0 raised during coverage: #{Exception.message(e)}"
         }}
    end
  end

  # ---------------------------------------------------------------------------
  # Coverage gathering
  # ---------------------------------------------------------------------------

  # Pulls `:cover.analyse(mod, :coverage, :line)` for every instrumented
  # module and folds the results into a `%{file => MapSet.t(line)}` map
  # keyed by the user-relative source path (r5).
  defp gather_covered_lines(cfg, instrumented) do
    cover_mod = Map.get(cfg, :cover, MutagenEx.Test.Cover)

    in_scope_files =
      cfg.in_scope_modules
      |> Enum.map(fn {_mod, file} -> file end)
      |> MapSet.new()

    result =
      Enum.reduce_while(instrumented, {:ok, %{}}, fn {module, file}, {:ok, acc} ->
        case analyse_module(cover_mod, module) do
          {:ok, lines} ->
            # r5: drop entries for files not in cfg.in_scope_modules even
            # if cover happens to surface them.
            updated =
              if MapSet.member?(in_scope_files, file) do
                set = Map.get(acc, file, MapSet.new())
                Map.put(acc, file, MapSet.union(set, lines))
              else
                acc
              end

            {:cont, {:ok, updated}}

          {:error, reason} ->
            {:halt,
             {:error, :cover_compile_failed,
              %{
                module: module,
                message: "cover.analyse(#{inspect(module)}) failed: #{inspect(reason)}"
              }}}
        end
      end)

    result
  end

  # `:cover.analyse(mod, :coverage, :line)` returns one of:
  #
  #   {:ok, [{{mod, line}, {covered, not_covered}}]}
  #   {:error, reason}
  #
  # We treat a line as covered if its `covered` count > 0.
  defp analyse_module(cover_mod, module) do
    case cover_mod.analyse(module, :coverage, :line) do
      {:ok, lines} when is_list(lines) ->
        set =
          lines
          |> Enum.reduce(MapSet.new(), fn
            {{^module, line}, {covered, _not_covered}}, acc
            when is_integer(line) and line > 0 and is_integer(covered) and covered > 0 ->
              MapSet.put(acc, line)

            _other, acc ->
              acc
          end)

        {:ok, set}

      {:error, _} = err ->
        err

      other ->
        {:error, {:unexpected_analyse_return, other}}
    end
  end

  # ---------------------------------------------------------------------------
  # Input normalisation
  # ---------------------------------------------------------------------------

  defp normalise(%{seed: seed, in_scope_modules: mods, test_filter: %TestFilter{}} = cfg)
       when is_integer(seed) and seed >= 0 and is_list(mods) do
    case Enum.all?(mods, &valid_module_entry?/1) do
      true ->
        {:ok, cfg}

      false ->
        {:error, :invalid_input, %{message: "in_scope_modules entries must be {module, file}"}}
    end
  end

  defp normalise(_), do: {:error, :invalid_input, %{message: "invalid CoverageRunner input"}}

  defp valid_module_entry?({mod, file}) when is_atom(mod) and is_binary(file), do: true
  defp valid_module_entry?(_), do: false
end
