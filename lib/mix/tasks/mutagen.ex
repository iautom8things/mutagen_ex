defmodule Mix.Tasks.Mutagen do
  @shortdoc "Run mutation testing against a scope, gated by cited tests"

  @moduledoc """
  # mix mutagen

  ## Synopsis

      mix mutagen --scope <target> --tests <target> [--timeout-ms N] [--seed N] [--json PATH] [--unsafe-json-outside-project]

  Run mutation testing against one or more scope targets, judged by a chosen
  set of tests. Emits a single JSON document to stdout (or `--json <path>`)
  describing every mutation, its outcome, and the surrounding run metadata.

  ## Flags

    * `--scope <target>` (required, repeatable) — what to mutate. One of:
      a file path ending in `.ex`, a module name (`Module.Name`), or
      `Module.Name.function/arity`. Repeat the flag to add more targets.
    * `--tests <target>` (required, repeatable) — which tests judge the
      mutations. One of: a test file path, a `file:line` reference, or
      `tag:<name>`. Repeat the flag to add more targets.
    * `--timeout-ms <int>` — wall-clock budget per mutation run, in
      milliseconds. Default `5000`. Must be a positive integer.
    * `--seed <int>` — ExUnit seed, propagated to every test-running phase.
      Default `0`. See Constraints.
    * `--json <path>` — write the final JSON document to `<path>` instead
      of stdout. The document always ends with a single newline. The path
      is canonicalised before any mutation runs: `..` segments and NUL
      bytes are refused at parse time, and the resolved path must stay
      inside the project root unless `--unsafe-json-outside-project` is
      also passed. Symlinks whose target escapes the project root are
      refused.
    * `--unsafe-json-outside-project` — opt-in to writing `--json` output
      outside the project root. CI integrations targeting an artifacts
      directory above the project root pass this flag; everyday use
      should leave it off. When set, a one-shot warning naming the
      resolved target lands on stderr at run start.

  ## Examples

      # Single file scope, single test file
      mix mutagen --scope lib/foo.ex --tests test/foo_test.exs

      # Multiple scopes, tag-based tests, custom timeout
      mix mutagen --scope MyApp.Foo --scope lib/bar.ex \\
                  --tests tag:fast --timeout-ms 10000

      # Module-and-function scope, deterministic seed, redirected output
      mix mutagen --scope MyApp.Foo.bar/1 --tests test/foo_test.exs \\
                  --seed 42 --json out/mutagen.json

  ## Constraints

    * Tests run **serially** (`max_cases: 1`) in every phase. There is no
      `--parallel` flag in v1 (see
      `mutagen.decision.serial_execution_and_seed`).
    * `--seed` controls **ExUnit test ordering** only. Mutation enumeration
      order is independent of the seed.
    * `mutagen_ex` runs **in-process** (same BEAM as your suite); see
      Caveats for the consequences (state drift, no self-mutation).

  ## Exit Codes

    * `0` — pipeline ran to completion, even if every mutation survived.
    * non-zero — bad input or unrecoverable error. Every non-zero exit also
      emits an error-JSON document to stdout (or `--json <path>`).

  ## JSON Schema Pointer

  The v1 output document is defined by-example via the golden fixtures
  committed at `test/mutagen_ex/golden/*.json`. Read these first:

    * `end_to_end_scenario_1_arith.json` — canonical successful run with
      a populated `mutation.results` array.
    * `end_to_end_scenario_5_baseline_red.json` — `aborted: true` with a
      populated `baseline.failures` block.
    * `end_to_end_scenario_6_zero_coverage.json` — successful run with
      zero coverage and an empty `mutation.results`.
    * `error_unresolvable_scope.json` — abort path where the pipeline
      never reaches the mutation phase.

  The behavioural contract for the shape itself lives in
  `.spec/specs/json_schema.spec.md`.

  ## Known Caveats

    * **State drift on `use SomeModule`.** Modules using compile-time DSLs
      can drift between baseline and mutation runs; the JSON `warnings`
      array names the affected modules.
    * **Macro mutation slowdown.** Mutations inside macro-heavy modules
      recompile dependents; expect longer per-site runs.
    * **Equivalent mutants.** Some mutations are semantically equivalent
      to the original; they survive every test by definition. This is a
      known limit of mutation testing, not a tool bug.
    * **`mix format` does not affect mutation IDs.** IDs are content-addressed
      against the parsed AST, not the source bytes (see
      `mutagen.decision.content_addressed_ids`).
    * **`--no-json` is not supported in v1.** Pretty terminal output is
      deferred to v1.1 (see `mutagen.decision.no_pretty_output_v1`); use
      `jq` for now.
    * **`--seed` controls ExUnit ordering only.** It does not seed mutation
      enumeration; that order is content-addressed and stable across runs.
    * **`--scope` colon syntax is unsupported.** `file.ex:Module` is rejected
      with `reason: :colon_syntax_unsupported` (see
      `mutagen.decision.scope_syntax_simplified`).
    * **Self-mutation is refused.** `--scope MutagenEx.*` or `Mix.Tasks.Mutagen`
      exits with `reason: :self_mutation_refused` (see
      `mutagen.decision.self_mutation_refused`).
    * **`--json` paths are canonicalised inside the project root.** Paths
      with `..` segments or NUL bytes exit with
      `reason: :unsafe_json_path` at parse time. Symlinks whose target
      escapes the project root exit the same way at canonicalisation
      time, before any mutation runs. CI workflows writing artifacts
      outside the project root must pass `--unsafe-json-outside-project`
      explicitly; a one-shot stderr warning then names the resolved
      target.
    * **`tag:NAME` charset is bounded.** `--tests tag:NAME` must match
      `~r/\\A[a-z][a-z_0-9]{0,63}\\z/` — lowercase ASCII, digits, or `_`,
      up to 64 chars, with a lowercase first character. Targets outside
      this charset are refused with `reason: :invalid_tag_name` before any
      test resolution runs. This is the atom-table-DOS bound (see
      `mutagen.cli.r11`, mutagen-wrd.20): CI loops like
      `mix mutagen --tests tag:$(uuidgen)` cannot grow the BEAM atom table.
  """

  use Mix.Task

  alias MutagenEx.CLI
  alias MutagenEx.Config
  alias MutagenEx.JsonReporter.Report

  @typedoc """
  Pluggable collaborators for the mix task's state machine. Each entry is a
  `{module, function}` pair the task uses instead of a hard-coded call, so
  every error path AND the happy path can be unit-tested by injecting fake
  collaborators that capture their arguments and return canned shapes.

  The keys correspond to the orchestration stages of
  `mutagen.mutation_pipeline`:

    * `:cli` — parse argv (`MutagenEx.CLI.parse/1`).
    * `:scope` — resolve each scope target (`MutagenEx.ScopeResolver.resolve/2`).
    * `:tests` — resolve test filter (`MutagenEx.TestSelector.resolve/2`).
    * `:ast_cache` — load AST + source per file (`MutagenEx.AstCache.load/2`).
    * `:coverage` — run coverage phase (`MutagenEx.CoverageRunner.run/1`).
    * `:enumerator` — enumerate mutation sites
      (`MutagenEx.MutationEnumerator.enumerate/4`).
    * `:baseline` — baseline phase (`MutagenEx.Baseline.run/1`).
    * `:mutation` — mutation phase (`MutagenEx.MutationRunner.run/1`).
    * `:reporter_ok` — emit success JSON (`MutagenEx.JsonReporter.emit_report/1`).
    * `:reporter_error` — emit abort JSON (`MutagenEx.JsonReporter.emit_error/2`).
    * `:io` — `{iodata, exit_code, Config.t()} -> :ok` sink for the final
      document. Default writes to stdout or `Config.json_path` and halts the
      VM with `exit_code`.

  S1 shipped a two-key shape (`:reporter`, `:pipeline`) for early CLI
  testing. Those keys still merge from defaults so the existing CLI
  tests keep working; when a caller passes `:pipeline` without the full
  phase set, the legacy code path runs.
  """
  @type dispatch :: %{
          optional(:cli) => {module(), atom()},
          optional(:scope) => {module(), atom()},
          optional(:tests) => {module(), atom()},
          optional(:ast_cache) => {module(), atom()},
          optional(:coverage) => {module(), atom()},
          optional(:enumerator) => {module(), atom()},
          optional(:baseline) => {module(), atom()},
          optional(:mutation) => {module(), atom()},
          optional(:reporter_ok) => {module(), atom()},
          optional(:reporter_error) => {module(), atom()},
          optional(:io) => {module(), atom()},
          optional(:reporter) => {module(), atom()},
          optional(:pipeline) => {module(), atom()}
        }

  @impl Mix.Task
  def run(argv) do
    run(argv, default_dispatch())
  end

  @doc """
  Test seam: run the task with a custom dispatch table.

  Production code calls `run/1`, which threads through `default_dispatch/0`.
  Tests pass a partial dispatch via `run/2` — any key absent from the
  passed map falls back to the default.

  The return value mirrors what `run/1` does observably:

    * `:ok` on a successful parse and pipeline run that produced a
      success-shape JSON document.
    * `{:aborted, reason, %Report{}}` on any abort path. The reporter and
      io collaborators have already been invoked with the iodata + exit
      code; the return value is for tests that want to assert which abort
      reason fired without parsing the emitted JSON.

  `run/1` itself does not return one of these — it calls `System.halt/1`
  via the default io collaborator on every path. `run/2` lets tests observe
  without halting the test VM by overriding the `:io` collaborator.
  """
  @spec run([String.t()], dispatch()) ::
          :ok
          | {:aborted, atom(), Report.t()}
          | {:error, CLI.reason(), map()}
  def run(argv, dispatch) when is_list(argv) and is_map(dispatch) do
    merged = Map.merge(default_dispatch(), dispatch)

    # S1's two-key legacy dispatch (test-only): if the test supplies
    # `:pipeline` without the new phase-level keys (no `:coverage`), route
    # through the legacy single-call shape so the existing S1 CLI tests
    # continue to pass without changes.
    cond do
      Map.has_key?(dispatch, :pipeline) and not Map.has_key?(dispatch, :coverage) ->
        run_legacy(argv, merged)

      true ->
        run_pipeline(argv, merged)
    end
  end

  # ---------------------------------------------------------------------------
  # Legacy two-collaborator dispatch (S1)
  # ---------------------------------------------------------------------------

  defp run_legacy(argv, dispatch) do
    {cli_mod, cli_fun} = Map.fetch!(dispatch, :cli)

    case apply(cli_mod, cli_fun, [argv]) do
      {:ok, config} ->
        {pipeline_mod, pipeline_fun} = Map.fetch!(dispatch, :pipeline)
        apply(pipeline_mod, pipeline_fun, [config])
        :ok

      {:error, reason, details} ->
        {reporter_mod, reporter_fun} = Map.fetch!(dispatch, :reporter)
        apply(reporter_mod, reporter_fun, [reason, details])
        {:error, reason, details}
    end
  end

  # ---------------------------------------------------------------------------
  # Full state machine
  # ---------------------------------------------------------------------------

  # Threads a `%Report{}` accumulator through the phases. Each phase
  # either returns `{:ok, update}` (continue) or
  # `{:error, phase, reason, details, partial_report}` (emit abort, halt).
  #
  # The six error-exits the ticket enumerates:
  #   1. CLI parse failure                  — missing_scope, invalid_timeout, etc.
  #   2. Scope resolution failure           — module_not_found, etc.
  #   3. Test selector failure              — no_tests_match, etc.
  #   4. AstCache failure                   — file_read_failed, parse_error
  #   5. Coverage phase failure             — cover_already_running, etc.
  #   6. Baseline-red OR mutation runner    — baseline_red,
  #                                           unrecoverable_restore_failure,
  #                                           self_mutation_refused
  defp run_pipeline(argv, dispatch) do
    case do_pipeline(argv, dispatch) do
      {:ok, report, config} ->
        emit_success(report, config, dispatch)

      {:abort, report, config, reason, details} ->
        emit_abort(report, config, reason, details, dispatch)
    end
  end

  defp do_pipeline(argv, dispatch) do
    report0 = base_report(nil)

    with {:ok, config} <- phase_cli(argv, dispatch),
         report1 = with_meta(report0, config),
         {:ok, config} <- phase_json_path(config, report1),
         {:ok, scope_records} <- phase_scope(config, dispatch, report1),
         report2 = %Report{report1 | scope: scope_records},
         {:ok, test_filter} <- phase_tests(config, dispatch, report2),
         report3 = %Report{report2 | tests: test_filter_to_wire(test_filter)},
         {:ok, ast_cache} <- phase_ast_cache(scope_records, dispatch, report3),
         {:ok, coverage_result} <-
           phase_coverage(config, scope_records, test_filter, dispatch, report3),
         report4 = %Report{report3 | coverage: coverage_to_report(coverage_result)},
         enum_result =
           phase_enumerator(ast_cache, scope_records, coverage_result, dispatch),
         {:ok, baseline_result} <-
           phase_baseline(config, test_filter, dispatch, report4),
         report5 = %Report{
           report4
           | baseline: baseline_to_report(baseline_result),
             warnings: report4.warnings ++ baseline_result.warnings
         },
         {:ok, mutation_result} <-
           phase_mutation(
             config,
             test_filter,
             ast_cache,
             enum_result.sites,
             scope_records,
             dispatch,
             report5
           ) do
      report = %Report{
        report5
        | mutation: mutation_to_report(mutation_result, enum_result),
          warnings:
            report5.warnings ++ enumerator_warnings(enum_result) ++ mutation_result.warnings,
          aborted: false,
          abort_reason: nil
      }

      {:ok, report, config}
    else
      {:abort, _report, _config, _reason, _details} = abort -> abort
    end
  end

  # ---------------------------------------------------------------------------
  # Phase wrappers
  # ---------------------------------------------------------------------------

  defp phase_cli(argv, dispatch) do
    {mod, fun} = Map.fetch!(dispatch, :cli)

    case apply(mod, fun, [argv]) do
      {:ok, %Config{}} = ok ->
        ok

      {:error, reason, details} ->
        {:abort, base_report(nil), nil, reason, details}
    end
  end

  # Canonicalises `--json <path>` BEFORE any mutation phase runs so a bad
  # path produces an abort-JSON document on stdout instead of:
  #   - writing the report to an arbitrary location, or
  #   - running mutations only to fail at write time.
  #
  # When the flag was not passed (`json_path: nil`), this phase is a no-op
  # — the document goes to stdout.
  #
  # When `unsafe_json_outside_project: true` is set, a startup warning
  # lands on stderr per `mutagen.cli.r10`. The warning is emitted exactly
  # once per run, at this phase.
  defp phase_json_path(%Config{json_path: nil} = config, _report), do: {:ok, config}

  defp phase_json_path(%Config{json_path: path} = config, report) do
    # Project root resolution: production uses `File.cwd!/0`. Tests
    # may override via the calling process's dictionary
    # (`Process.put(:mutagen_json_path_project_root, "/tmp/...")`) so
    # they can plant symlinks in an isolated tmp dir without changing
    # cwd — which would race with parallel ExUnit test loading. The
    # process dictionary scope is the test process itself; no global
    # state, no cross-test contamination.
    project_root = Process.get(:mutagen_json_path_project_root) || File.cwd!()

    opts = [
      project_root: project_root,
      unsafe_outside_project: config.unsafe_json_outside_project
    ]

    case MutagenEx.JsonPath.canonicalize(path, opts) do
      {:ok, canonical} ->
        if config.unsafe_json_outside_project do
          IO.puts(
            :stderr,
            "warning: --unsafe-json-outside-project is set; " <>
              "writing report to #{canonical} which may be outside the project root"
          )
        end

        {:ok, %Config{config | json_path: canonical}}

      {:error, reason, details} ->
        {:abort, report, config, reason, details}
    end
  end

  defp phase_scope(%Config{scopes: scopes} = config, dispatch, %Report{} = report) do
    {mod, fun} = Map.fetch!(dispatch, :scope)

    Enum.reduce_while(scopes, {:ok, []}, fn target, {:ok, acc} ->
      case apply(mod, fun, [target, []]) do
        {:ok, records} ->
          {:cont, {:ok, acc ++ records}}

        {:error, reason, details} ->
          partial = %Report{report | scope: acc}

          {:halt,
           {:abort, partial, config, reason, Map.put_new(details, :target, target)}}
      end
    end)
  end

  defp phase_tests(%Config{tests: tests} = config, dispatch, report) do
    {mod, fun} = Map.fetch!(dispatch, :tests)

    case apply(mod, fun, [tests, []]) do
      {:ok, filter} ->
        {:ok, filter}

      {:error, %{reason: reason} = details} ->
        {:abort, report, config, reason, details}

      {:error, reason, details} when is_atom(reason) ->
        {:abort, report, config, reason, details}
    end
  end

  defp phase_ast_cache(scope_records, dispatch, report) do
    {mod, fun} = Map.fetch!(dispatch, :ast_cache)

    files = scope_records |> Enum.map(& &1.file) |> Enum.uniq()

    case apply(mod, fun, [files, []]) do
      {:ok, cache} ->
        {:ok, cache}

      {:error, reason, details} ->
        {:abort, report, nil, reason, details}
    end
  end

  defp phase_coverage(%Config{seed: seed} = config, scope_records, test_filter, dispatch, report) do
    {mod, fun} = Map.fetch!(dispatch, :coverage)

    in_scope_modules =
      scope_records
      |> Enum.map(&{&1.module, &1.file})
      |> Enum.uniq()

    input = %{
      seed: seed,
      in_scope_modules: in_scope_modules,
      test_filter: test_filter
    }

    case apply(mod, fun, [input]) do
      {:ok, result} ->
        {:ok, result}

      {:error, reason, details} ->
        {:abort, report, config, reason, details}
    end
  end

  defp phase_enumerator(ast_cache, scope_records, coverage_result, dispatch) do
    {mod, fun} = Map.fetch!(dispatch, :enumerator)

    covered_lines = coverage_result.covered_lines
    apply(mod, fun, [ast_cache, scope_records, covered_lines, []])
  end

  defp phase_baseline(%Config{seed: seed} = config, test_filter, dispatch, %Report{} = report) do
    {mod, fun} = Map.fetch!(dispatch, :baseline)

    input = %{seed: seed, test_filter: test_filter}

    case apply(mod, fun, [input]) do
      {:ok, result} ->
        {:ok, result}

      {:error, :baseline_red, details} ->
        # r1: baseline failures populate `baseline` on the abort report.
        partial_baseline = %{
          "passed" => Map.get(details, :passed, 0),
          "failed" =>
            Map.get(details, :failed, length(Map.get(details, :failures, []))),
          "failures" => Enum.map(Map.get(details, :failures, []), &failure_to_wire/1)
        }

        partial = %Report{report | baseline: partial_baseline}
        {:abort, partial, config, :baseline_red, details}

      {:error, reason, details} ->
        {:abort, report, config, reason, details}
    end
  end

  defp phase_mutation(
         %Config{seed: seed, timeout_ms: timeout_ms} = config,
         test_filter,
         ast_cache,
         sites,
         scope_records,
         dispatch,
         report
       ) do
    {mod, fun} = Map.fetch!(dispatch, :mutation)

    # `MutationLoop` re-registers `test_modules` with `ExUnit.Server`
    # before every per-site `ExUnit.run/0` because the server consumes
    # its registered-module list per run. With the hardcoded `[]` this
    # used to be, every site reported zero tests and every mutation was
    # classified `:survived` (mutagen-wrd.12). Derive from the resolved
    # `test_filter.files` so the production pipeline matches what
    # `mutagen.mutation_pipeline.r5` requires.
    input = %{
      seed: seed,
      timeout_ms: timeout_ms,
      test_filter: test_filter,
      ast_cache: ast_cache,
      sites: sites,
      scope_records: scope_records,
      test_modules: MutagenEx.TestModuleDiscovery.discover(test_filter.files)
    }

    case apply(mod, fun, [input]) do
      {:ok, result} ->
        {:ok, result}

      {:error, reason, details} ->
        {:abort, report, config, reason, details}
    end
  end

  # ---------------------------------------------------------------------------
  # Report building
  # ---------------------------------------------------------------------------

  # Every variant — including a `cli` parse failure where `Config` does
  # not yet exist — needs a populated `meta` block per
  # `mutagen.json_schema.r5`.
  defp base_report(seed) do
    %Report{
      meta: %{
        tool_version: tool_version(),
        elixir_version: System.version(),
        otp_version: otp_version(),
        exunit_seed: seed || 0
      },
      scope: [],
      warnings: []
    }
  end

  defp with_meta(%Report{} = r, %Config{seed: seed}) do
    %Report{r | meta: Map.put(r.meta, :exunit_seed, seed)}
  end

  defp tool_version do
    case Application.spec(:mutagen_ex, :vsn) do
      nil -> "0.0.0-dev"
      v -> to_string(v)
    end
  end

  defp otp_version do
    :erlang.system_info(:otp_release) |> to_string()
  end

  defp test_filter_to_wire(%MutagenEx.TestSelector.TestFilter{} = f) do
    %{include: f.include, exclude: f.exclude, files: f.files}
  end

  defp test_filter_to_wire(other), do: other

  defp coverage_to_report(%{covered_lines: covered}) do
    %{covered_lines: covered}
  end

  defp baseline_to_report(%{passed: p, failed: f, failures: fails}) do
    %{passed: p, failed: f, failures: fails}
  end

  # Per `mutagen.json_schema.r3`:
  #   total      = killed + survived + timeout + error  (all completed
  #                non-compile-error sites)
  #   completed  = same set
  #   kill_rate  = killed / (total - compile_error) when denominator > 0
  #
  # In v1 we model `total` as the count of non-skipped, non-compile-error
  # sites the runner attempted — exactly the four classifying outcomes.
  defp mutation_to_report(mutation_result, enum_result) do
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

    rendered_results = Enum.map(results, &render_result/1)

    %{
      total: total,
      completed: completed,
      killed: killed,
      survived: survived,
      timeout: timeout,
      compile_error: compile_error_count,
      kill_rate: kill_rate,
      results: rendered_results,
      skipped: enum_result.skipped,
      compile_errors: compile_errors,
      state_drift_warning: mutation_result.state_drift_warning
    }
  end

  defp render_result(r) do
    %{
      id: r.id,
      file: r.file,
      line: r.line,
      column: r.column,
      mutator: r.mutator,
      before: Macro.to_string(r.original_ast),
      before_source: Macro.to_string(r.original_ast),
      after: Macro.to_string(r.mutated_ast),
      status: r.status,
      tainted_predecessors: r.tainted_predecessors,
      warnings: r.warnings
    }
  end

  defp enumerator_warnings(%{warnings: ws}) when is_list(ws) do
    Enum.map(ws, fn
      {:no_mutation_candidates, mod} ->
        "no_mutation_candidates: #{inspect(mod)}"

      other ->
        inspect(other)
    end)
  end

  defp enumerator_warnings(_), do: []

  defp failure_to_wire({module, name}),
    do: %{"module" => inspect(module), "name" => to_string(name)}

  defp failure_to_wire(%{module: module, name: name}),
    do: %{"module" => inspect(module), "name" => to_string(name)}

  # ---------------------------------------------------------------------------
  # Emission
  # ---------------------------------------------------------------------------

  defp emit_success(%Report{} = report, %Config{} = config, dispatch) do
    {mod, fun} = Map.fetch!(dispatch, :reporter_ok)
    {iodata, code} = apply(mod, fun, [report])

    {io_mod, io_fun} = Map.fetch!(dispatch, :io)
    apply(io_mod, io_fun, [iodata, code, config])
    :ok
  end

  defp emit_abort(%Report{} = report, config, reason, _details, dispatch) do
    {mod, fun} = Map.fetch!(dispatch, :reporter_error)
    {iodata, code} = apply(mod, fun, [report, reason])

    {io_mod, io_fun} = Map.fetch!(dispatch, :io)
    apply(io_mod, io_fun, [iodata, code, config])

    {:aborted, reason,
     %Report{report | aborted: true, abort_reason: Atom.to_string(reason)}}
  end

  # ---------------------------------------------------------------------------
  # Defaults
  # ---------------------------------------------------------------------------

  @doc false
  # Exposed only for `run/1`. Tests pass a (partial) dispatch via
  # `run/2`; missing keys fall back here.
  @spec default_dispatch() :: dispatch()
  def default_dispatch do
    %{
      cli: {MutagenEx.CLI, :parse},
      scope: {MutagenEx.ScopeResolver, :resolve},
      tests: {MutagenEx.TestSelector, :resolve},
      ast_cache: {MutagenEx.AstCache, :load},
      coverage: {MutagenEx.CoverageRunner, :run},
      enumerator: {MutagenEx.MutationEnumerator, :enumerate},
      baseline: {MutagenEx.Baseline, :run},
      mutation: {MutagenEx.MutationRunner, :run},
      reporter_ok: {MutagenEx.JsonReporter, :emit_report},
      reporter_error: {MutagenEx.JsonReporter, :emit_error},
      io: {__MODULE__, :default_io},
      # S1 back-compat — only reached via the legacy code path.
      reporter: {__MODULE__, :default_report_error},
      pipeline: {__MODULE__, :default_run_pipeline}
    }
  end

  @doc false
  # Default IO sink: writes iodata to stdout or `Config.json_path`, then
  # halts the BEAM with `exit_code`. State-machine tests override this
  # with a process-message capture so the test VM stays alive.
  @spec default_io(iodata(), non_neg_integer(), Config.t() | nil) :: no_return()
  def default_io(iodata, exit_code, config) do
    case config do
      %Config{json_path: nil} ->
        IO.write(iodata)

      %Config{json_path: path} when is_binary(path) ->
        File.write!(path, iodata)

      _ ->
        IO.write(iodata)
    end

    System.halt(exit_code)
  end

  @doc false
  # Legacy S1 error reporter; called only when the legacy dispatch
  # shape is used (a test passes `:pipeline` without the full key set).
  @spec default_report_error(CLI.reason(), map()) :: no_return()
  def default_report_error(reason, details) do
    message = Map.get(details, :message, "mutagen: error")
    Mix.shell().error("mutagen: error (#{reason}) — #{message}")
    System.halt(2)
  end

  @doc false
  # Legacy S1 pipeline placeholder; superseded by the full state machine
  # in `run_pipeline/2`. Retained so the S1 default dispatch shape still
  # type-checks for back-compat. Not reachable through `run/1`.
  @spec default_run_pipeline(Config.t()) :: no_return()
  def default_run_pipeline(_config) do
    raise "legacy S1 pipeline placeholder — superseded by Mix.Tasks.Mutagen.run_pipeline/2"
  end
end
