defmodule MutagenEx.Baseline do
  @moduledoc """
  Pre-mutation test pass: do the cited tests pass on unmodified code?

  Contract: [`mutagen.mutation_pipeline`](../../.spec/specs/mutation_pipeline.spec.md)
  r1, r2.

  ## Responsibilities (and what it deliberately is NOT)

    * **r1.** `run/1` runs the cited tests once with no mutation applied.
      If any test fails, return `{:error, :baseline_red, %{failures:
      [{module, name}, ...], passed: int}}`. The orchestrator then routes
      the failure into the universal error-JSON shape.
    * **r2.** Forces `ExUnit.configure(max_cases: 1, seed: cfg.seed)`
      before the run. Detects `async: true` test modules in the cited
      filter and surfaces them as warnings (so the JSON's `warnings`
      array can be populated downstream).

  Baseline does NOT own:

    * Per-mutation timeouts (no timeout wrapping; if the baseline hangs,
      the user can Ctrl-C — per `mutagen.decision.mutation_loop_private`).
    * Stdout/stderr suppression (baseline runs ExUnit's own formatters by
      default; the orchestrator can `ExUnit.CaptureIO`-wrap the call if
      it doesn't want the banner).
    * Cover instrumentation (that's `MutagenEx.CoverageRunner`).
    * Loading test files (that's the orchestrator: see
      `MutagenEx.CoverageRunner` for the precedent; baseline does it once
      because tests can run only once per `require_file` per `r10`).

  ## Input shape

  A map with:

    * `:seed` — non-negative integer.
    * `:test_filter` — `%MutagenEx.TestSelector.TestFilter{}`.

  Optional:

    * `:ex_unit` — module implementing `MutagenEx.Test.ExUnitFacade`
      (test seam). Defaults to `MutagenEx.Test.ExUnit`, which delegates
      to the real `ExUnit`. Tests pass their own module with the same
      callback surface.
    * `:test_loader` — `(path -> any)` overriding `Code.require_file/1`.
    * `:ast_cache` — `MutagenEx.AstCache.t()`. Optional. When present,
      `detect_async_modules/1` (the r2 async-warning path) looks each
      cited test file up in the cache via `AstCache.get/2` and consumes
      the cached `{ast, _source}` directly — no re-read from disk. On
      `:error` (cache miss), the implementation falls back to the
      pre-`.25` `File.read/1` path as a safety net and logs the miss.
      When `:ast_cache` is absent, the fall-back path is the only path
      (preserves pre-`.25` behaviour for callers that haven't wired the
      cache through yet). See `mutagen.coverage.r9`.
  """

  require Logger

  alias MutagenEx.AstCache
  alias MutagenEx.TestSelector.TestFilter

  @behaviour MutagenEx.Pipeline.BaselineFacade

  @typedoc "Reasons the baseline can return."
  @type error_reason ::
          :baseline_red
          | :ex_unit_run_failed
          | :test_file_load_failed
          | :invalid_input

  @typedoc "Successful baseline result."
  @type ok_result :: %{
          passed: non_neg_integer(),
          failed: non_neg_integer(),
          failures: [{module(), String.t() | atom()}],
          warnings: [String.t()]
        }

  @doc """
  Run the baseline. Returns `{:ok, %{passed:, failed: 0, failures: [],
  warnings: [...]}}` on full success or `{:error, :baseline_red,
  %{failures: [...], passed: n}}` on any failing cited test.
  """
  @impl MutagenEx.Pipeline.BaselineFacade
  @spec run(map()) :: {:ok, ok_result()} | {:error, error_reason(), map()}
  def run(input) when is_map(input) do
    with {:ok, cfg} <- normalise(input),
         :ok <- configure_exunit(cfg),
         :ok <- load_test_files(cfg),
         {:ok, exunit_result} <- run_exunit(cfg) do
      classify(exunit_result, cfg)
    end
  end

  # ---------------------------------------------------------------------------
  # Pipeline steps
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
              message:
                MutagenEx.JsonReporter.Sanitizer.clean(
                  "could not load test file #{inspect(file)}: #{Exception.message(e)}"
                )
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
           message:
             MutagenEx.JsonReporter.Sanitizer.clean(
               "ExUnit.run/0 raised during baseline: #{Exception.message(e)}"
             )
         }}
    end
  end

  # ExUnit.run/0 returns a map shape like
  # `%{failures: int, total: int, excluded: int, skipped: int}`. The map
  # is plain data — we don't get failure module/test detail from it, so
  # the orchestrator may want to attach a richer failure list via an
  # ExUnit formatter in future. For v1, the baseline failure detail is
  # populated from the orchestrator-provided `:failure_collector` seam
  # (defaults to a no-op that returns `[]`).
  #
  # The collector seam lets the orchestrator wire a real formatter (e.g.
  # one that records `{module, test_name}` pairs) into the baseline phase
  # without making Baseline itself a top-level ExUnit formatter.
  defp classify(exunit_result, cfg) when is_map(exunit_result) do
    failures = Map.get(exunit_result, :failures, 0)
    total = Map.get(exunit_result, :total, 0)

    passed =
      max(
        0,
        total - failures - Map.get(exunit_result, :excluded, 0) -
          Map.get(exunit_result, :skipped, 0)
      )

    collector = Map.get(cfg, :failure_collector, fn -> [] end)
    failure_list = collector.()

    warnings = async_warnings(cfg)

    if failures > 0 do
      {:error, :baseline_red,
       %{
         passed: passed,
         failed: failures,
         failures: failure_list,
         warnings: warnings,
         message: "baseline: #{failures} test failure(s) before any mutation"
       }}
    else
      {:ok,
       %{
         passed: passed,
         failed: 0,
         failures: [],
         warnings: warnings
       }}
    end
  end

  defp classify(other, _cfg) do
    {:error, :ex_unit_run_failed,
     %{
       message: "ExUnit.run/0 returned an unexpected shape (#{inspect(other)})"
     }}
  end

  # r2 second clause: detect `async: true` test modules in the cited
  # filter and surface them as warnings. We inspect each test file's AST
  # for `use ExUnit.Case, async: true` without loading the module — that
  # would defeat the once-per-run load contract.
  #
  # Post-`.25.3` (F18 / mutagen.coverage.r9): when the caller hands us an
  # `:ast_cache` we consult it via `AstCache.get/2` and consume the
  # cached `{ast, _source}` directly — no re-read of test files from
  # disk. On `:error` (cache miss) we fall back to the pre-`.25`
  # `File.read/1` path as a safety net and log the miss for diagnostics.
  # When no cache is supplied, the fall-back path is the only path.
  defp async_warnings(cfg) do
    cache = Map.get(cfg, :ast_cache)

    cfg.test_filter.files
    |> Enum.flat_map(&detect_async_modules(&1, cache))
    |> Enum.uniq()
  end

  defp detect_async_modules(file, nil) do
    fallback_detect(file)
  end

  defp detect_async_modules(file, cache) when is_map(cache) do
    case AstCache.get(cache, file) do
      {:ok, {ast, _source}} ->
        collect_async_modules(ast)

      :error ->
        Logger.debug(fn ->
          "Baseline.detect_async_modules: cache miss for #{inspect(file)}; " <>
            "falling back to File.read/1"
        end)

        fallback_detect(file)
    end
  end

  defp fallback_detect(file) do
    with {:ok, source} <- File.read(file),
         {:ok, ast} <- Code.string_to_quoted(source, columns: true, file: file) do
      collect_async_modules(ast)
    else
      _ -> []
    end
  end

  defp collect_async_modules(ast) do
    {_, acc} =
      Macro.prewalk(ast, [], fn
        {:defmodule, _meta, [_alias_ast, [do: _body]]} = node, acc ->
          if module_uses_async_case?(node) do
            mod_name = module_name(node)
            if mod_name, do: {node, [warning_string(mod_name) | acc]}, else: {node, acc}
          else
            {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(acc)
  end

  # Detect `use ExUnit.Case, async: true` within a defmodule body. We
  # accept either the alias form `ExUnit.Case` and the explicit
  # `Module` form; arbitrary other `use` calls are ignored.
  defp module_uses_async_case?({:defmodule, _meta, [_alias_ast, [do: body]]}) do
    {_ast, found} =
      Macro.prewalk(body, false, fn
        {:use, _meta, [target | rest]} = node, _acc ->
          target_is_exunit_case = exunit_case?(target)
          opts = List.last(rest)
          {node, target_is_exunit_case and async_opt_true?(opts)}

        node, acc ->
          {node, acc}
      end)

    found
  end

  defp exunit_case?({:__aliases__, _meta, [:ExUnit, :Case]}), do: true
  defp exunit_case?(ExUnit.Case), do: true
  defp exunit_case?(_), do: false

  defp async_opt_true?(opts) when is_list(opts) do
    Keyword.get(opts, :async) == true
  end

  defp async_opt_true?(_), do: false

  defp module_name({:defmodule, _meta, [{:__aliases__, _, parts}, _]}) when is_list(parts) do
    if Enum.all?(parts, &is_atom/1), do: Module.concat(parts), else: nil
  end

  defp module_name(_), do: nil

  defp warning_string(mod) do
    "async_module: " <>
      inspect(mod) <>
      " — cited test module declared `async: true`. " <>
      "Pipeline forced max_cases: 1; per-test ordering is serial regardless."
  end

  # ---------------------------------------------------------------------------
  # Input normalisation
  # ---------------------------------------------------------------------------

  defp normalise(%{seed: seed, test_filter: %TestFilter{}} = cfg)
       when is_integer(seed) and seed >= 0,
       do: {:ok, cfg}

  defp normalise(_), do: {:error, :invalid_input, %{message: "invalid Baseline input"}}
end
