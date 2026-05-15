defmodule Mix.Tasks.Mutagen do
  @shortdoc "Run mutation testing against a scope, gated by cited tests"

  @moduledoc """
  # mix mutagen

  ## Synopsis

      mix mutagen --scope <target> --tests <target> [--timeout-ms N] [--seed N] [--json PATH] [--unsafe-json-outside-project] [--max-sites N] [--budget-ms N]

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
    * `--max-sites <int>` — upper bound on enumerated mutation sites
      for one run. Default `10000`. The enumerator aborts with
      `:too_many_sites` BEFORE the runner starts when the cap is
      exceeded; narrow `--scope` (or raise the cap) to proceed.
    * `--budget-ms <int>` — aggregate wall-clock budget for the
      mutation phase, in milliseconds. Optional (default: unbounded;
      the per-site `--timeout-ms` is still enforced). When the budget
      elapses the runner stops dispatching new sites and emits a
      `truncated: true` partial report.

  ## Caps

    * `--scope` and `--tests` each accept at most 100 occurrences. Excess
      is refused at parse time with `reason: :too_many_targets`.
    * `--max-sites` caps enumerated mutation sites (default 10_000).
    * `--budget-ms` (optional) caps aggregate wall-clock for the
      mutation phase. The per-site `--timeout-ms` still applies.

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
    * **Caps on input and output volume.** `--scope` and `--tests` each
      accept at most 100 occurrences (`reason: :too_many_targets`).
      `--max-sites` caps enumerated mutation sites (default 10_000;
      `reason: :too_many_sites`). `--budget-ms` (optional) caps the
      aggregate mutation wall-clock and yields a `truncated: true`
      partial report when exhausted.
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
    # Per `mutagen.mutation_pipeline.r15`, the `[:mutagen_ex, :run,
    # :start]` event fires once at pipeline entry. The `:run, :stop`
    # event fires at exit (success or abort).
    started_at = System.monotonic_time()

    MutagenEx.Telemetry.execute(
      [:mutagen_ex, :run, :start],
      %{system_time: System.system_time()},
      %{argv: argv}
    )

    # Subscribe the progress handler (when enabled) before the
    # mutation phase starts so site `.stop` events get drawn live.
    progress_handler_id = maybe_attach_progress_handler(argv)

    try do
      result =
        case do_pipeline(argv, dispatch) do
          {:ok, report, config} ->
            maybe_emit_stream_end(report, config)
            emit_run_stop(report, started_at, false, nil)
            emit_success(report, config, dispatch)

          {:abort, %Report{} = report, config, reason, details} ->
            maybe_emit_stream_end(
              %Report{report | aborted: true, abort_reason: Atom.to_string(reason)},
              config
            )

            emit_run_stop(report, started_at, true, reason)
            emit_abort(report, config, reason, details, dispatch)
        end

      result
    after
      _ = maybe_detach_progress_handler(progress_handler_id)
    end
  end

  # Argv-scan for `--no-progress` to decide attachment. We do this at
  # entry (before phase_cli parses) so the handler is attached over
  # the entire pipeline; if the user passed `--no-progress` we never
  # subscribe in the first place. A full `--progress=auto` decision
  # happens in `MutagenEx.Progress.enabled?/1` once we have a Config.
  defp maybe_attach_progress_handler(argv) do
    progress =
      cond do
        "--no-progress" in argv -> :off
        true -> :auto
      end

    if MutagenEx.Progress.enabled?(progress) do
      id = {:mutagen_ex_progress, make_ref()}

      :telemetry.attach(
        id,
        [:mutagen_ex, :site, :stop],
        fn _event, _measurements, metadata, _config ->
          MutagenEx.Progress.report(metadata)
        end,
        nil
      )

      id
    else
      nil
    end
  end

  defp maybe_detach_progress_handler(nil), do: :ok
  defp maybe_detach_progress_handler(id), do: :telemetry.detach(id)

  defp emit_run_stop(%Report{} = report, started_at, aborted, reason) do
    duration = System.monotonic_time() - started_at
    mutation = report.mutation || %{}

    MutagenEx.Telemetry.execute(
      [:mutagen_ex, :run, :stop],
      %{duration: duration},
      %{
        aborted: aborted,
        abort_reason: reason && Atom.to_string(reason),
        killed: Map.get(mutation, :killed, 0),
        survived: Map.get(mutation, :survived, 0),
        timeout: Map.get(mutation, :timeout, 0),
        compile_error: Map.get(mutation, :compile_error, 0),
        error: 0
      }
    )
  end

  defp maybe_emit_stream_end(%Report{} = report, %Config{stream: true} = config) do
    sink = stream_sink(config, %{})
    MutagenEx.JsonStreamer.emit_end(sink, report)
  end

  defp maybe_emit_stream_end(_, _), do: :ok

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
         {:ok, enum_result} <-
           phase_enumerator(config, ast_cache, scope_records, coverage_result, dispatch, report4),
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
          abort_reason: nil,
          truncated: Map.get(mutation_result, :truncated, false) == true
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

  # Per-target scope resolution. The accumulator holds **reversed** chunks
  # of records so the per-target merge is O(records_per_target) rather
  # than O(total_records_so_far) — the `acc ++ records` shape this
  # replaced was O(n²) over the cumulative record count (bw mutagen-wrd.22
  # / F28). We prepend each new chunk (already in the same order as it
  # came out of the resolver), and flatten-reverse at the end via
  # `:lists.append(:lists.reverse(acc))` which preserves the original
  # input order while staying linear.
  defp phase_scope(%Config{scopes: scopes} = config, dispatch, %Report{} = report) do
    {mod, fun} = Map.fetch!(dispatch, :scope)

    result =
      Enum.reduce_while(scopes, {:ok, []}, fn target, {:ok, acc} ->
        case apply(mod, fun, [target, []]) do
          {:ok, records} ->
            {:cont, {:ok, [records | acc]}}

          {:error, reason, details} ->
            partial = %Report{report | scope: :lists.append(:lists.reverse(acc))}

            {:halt,
             {:abort, partial, config, reason, Map.put_new(details, :target, target)}}
        end
      end)

    case result do
      {:ok, chunks_reversed} ->
        {:ok, :lists.append(:lists.reverse(chunks_reversed))}

      {:abort, _, _, _, _} = abort ->
        abort
    end
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

    # `mutagen.mutation_pipeline.r15`: `[:mutagen_ex, :coverage, :start
    # | :stop]` brackets the coverage phase. The `.stop` metadata
    # carries `covered_files` and `covered_lines` so a telemetry
    # subscriber can report progress without re-walking the result.
    MutagenEx.Telemetry.span(
      :coverage,
      %{in_scope_modules: length(in_scope_modules)},
      fn ->
        case apply(mod, fun, [input]) do
          {:ok, result} ->
            covered = result.covered_lines

            stop_meta = %{
              covered_files: map_size(covered),
              covered_lines:
                Enum.reduce(covered, 0, fn {_f, lines}, acc ->
                  acc + line_count(lines)
                end)
            }

            {{:ok, result}, stop_meta}

          {:error, reason, details} ->
            {{:abort, report, config, reason, details},
             %{aborted: true, abort_reason: Atom.to_string(reason)}}
        end
      end
    )
  end

  defp line_count(lines) when is_list(lines), do: length(lines)
  defp line_count(%MapSet{} = lines), do: MapSet.size(lines)
  defp line_count(lines) when is_bitstring(lines), do: byte_size(lines)
  defp line_count(_), do: 0

  # `--max-sites` flows in here so an over-budget enumeration aborts
  # before the runner even starts. The enumerator returns
  # `{:error, :too_many_sites, details}` when the produced sites would
  # exceed `Config.max_sites`; that becomes an abort-JSON document so
  # the user gets a structured "your scope is too large, narrow it"
  # signal rather than an OOM.
  #
  # Per `mutagen.mutation_pipeline.r15`, `[:mutagen_ex, :enumeration,
  # :stop]` is a fire-and-forget telemetry event (we don't wrap
  # enumeration in a span because the enumerator is fast and
  # synchronous; the measurement that matters is the site count).
  defp phase_enumerator(
         %Config{max_sites: max_sites} = config,
         ast_cache,
         scope_records,
         coverage_result,
         dispatch,
         %Report{} = report
       ) do
    {mod, fun} = Map.fetch!(dispatch, :enumerator)

    covered_lines = coverage_result.covered_lines

    case apply(mod, fun, [ast_cache, scope_records, covered_lines, [max_sites: max_sites]]) do
      %{sites: _, skipped: _, warnings: _} = enum_result ->
        MutagenEx.Telemetry.execute(
          [:mutagen_ex, :enumeration, :stop],
          %{sites: length(Map.get(enum_result, :sites, []))},
          %{skipped: length(Map.get(enum_result, :skipped, []))}
        )

        {:ok, enum_result}

      {:error, :too_many_sites, details} ->
        MutagenEx.Telemetry.execute(
          [:mutagen_ex, :enumeration, :stop],
          %{sites: 0},
          %{skipped: 0, aborted: true, abort_reason: "too_many_sites"}
        )

        {:abort, report, config, :too_many_sites, details}
    end
  end

  defp phase_baseline(%Config{seed: seed} = config, test_filter, dispatch, %Report{} = report) do
    {mod, fun} = Map.fetch!(dispatch, :baseline)

    input = %{seed: seed, test_filter: test_filter}

    # `mutagen.mutation_pipeline.r15`: `[:mutagen_ex, :baseline, :start
    # | :stop]` brackets baseline. The `.stop` metadata carries
    # `passed` and `failed` so consumers can detect baseline-red
    # without parsing the JSON.
    MutagenEx.Telemetry.span(
      :baseline,
      %{},
      fn ->
        case apply(mod, fun, [input]) do
          {:ok, result} ->
            {{:ok, result},
             %{passed: result.passed, failed: result.failed}}

          {:error, :baseline_red, details} ->
            partial_baseline = %{
              "passed" => Map.get(details, :passed, 0),
              "failed" =>
                Map.get(details, :failed, length(Map.get(details, :failures, []))),
              "failures" => Enum.map(Map.get(details, :failures, []), &failure_to_wire/1)
            }

            partial = %Report{report | baseline: partial_baseline}

            {{:abort, partial, config, :baseline_red, details},
             %{passed: Map.get(details, :passed, 0),
               failed:
                 Map.get(details, :failed, length(Map.get(details, :failures, []))),
               aborted: true,
               abort_reason: "baseline_red"}}

          {:error, reason, details} ->
            {{:abort, report, config, reason, details},
             %{aborted: true, abort_reason: Atom.to_string(reason)}}
        end
      end
    )
  end

  defp phase_mutation(
         %Config{seed: seed, timeout_ms: timeout_ms, budget_ms: budget_ms} = config,
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
    #
    # `budget_ms` (from `--budget-ms`, mutagen.cli.r13) is an optional
    # aggregate wall-clock cap. `nil` means unbounded.
    #
    # Per `mutagen.mutation_pipeline.r15`, `--max-concurrency` is
    # threaded into the runner here. Both the Mix task and the runner
    # resolve `Config.max_concurrency == nil` to `1` (fully-serial,
    # v1.0-equivalent); callers opt in to parallelism by passing
    # `--max-concurrency N` (N > 1) explicitly. Default-1 is the
    # honest reflection of the in-process pipeline's shared ExUnit /
    # Code.Server / cover state — see the caveat paragraph in r15.
    #
    # When `--stream` is set, the `:on_site_completed` seam emits one
    # NDJSON line per site (in input order) to the same sink the final
    # document goes to. `start` and `end` envelope lines bracket the
    # stream so naive consumers can `JSON.parse(line)` and route on
    # the `"kind"` discriminator.
    site_sink = stream_sink(config, dispatch)

    if config.stream do
      MutagenEx.JsonStreamer.emit_start(site_sink, length(sites),
        Map.from_struct(report.meta || %{})
        |> Map.put_new(:tool_version, "0.0.0-dev")
      )
    end

    on_site_completed =
      if config.stream do
        fn
          {:result, result_map} -> MutagenEx.JsonStreamer.emit_result(site_sink, result_map)
          {:compile_error, entry} -> MutagenEx.JsonStreamer.emit_compile_error(site_sink, entry)
        end
      else
        fn _ -> :ok end
      end

    # The in-process pipeline shares ExUnit globals, the Code.Server,
    # and `:cover` across all per-site tasks. Two parallel tasks
    # mutating the same module's bytecode collide on
    # `Code.compile_quoted/1`; two parallel `ExUnit.run/0` calls
    # interleave the global `ExUnit.Server` state. Real-world
    # parallelism therefore requires either per-task ExUnit servers
    # (out of scope for v1.1) or strict per-site serialization.
    #
    # Setting `--max-concurrency 1` explicitly is equivalent to the
    # default; setting `--max-concurrency N` (N > 1) is the opt-in
    # path. The runner itself enforces ordered collection so the
    # byte-identical-output gate (`mutagen.mutation_pipeline.r15`)
    # holds independent of N on deterministic input.
    resolved_max_concurrency = config.max_concurrency || 1

    input = %{
      seed: seed,
      timeout_ms: timeout_ms,
      budget_ms: budget_ms,
      test_filter: test_filter,
      ast_cache: ast_cache,
      sites: sites,
      scope_records: scope_records,
      test_modules: MutagenEx.TestModuleDiscovery.discover(test_filter.files),
      max_concurrency: resolved_max_concurrency,
      on_site_completed: on_site_completed
    }

    case apply(mod, fun, [input]) do
      {:ok, result} ->
        {:ok, result}

      {:error, reason, details} ->
        {:abort, report, config, reason, details}
    end
  end

  # The streaming sink resolves to the same destination as the final
  # aggregate document: stdout when `--json` is not set, otherwise the
  # canonicalised file path. The `--stream` mode appends per-site
  # lines AND the final aggregate document; consumers reading the
  # destination see N+2 JSON values (start, N per-site, end) followed
  # by one aggregate doc. The dispatch's `:io` key is the production
  # default's sink for the aggregate; the streamer writes incrementally
  # so we keep an open append handle for file outputs.
  defp stream_sink(%Config{json_path: nil}, _dispatch), do: :standard_io

  defp stream_sink(%Config{json_path: path}, _dispatch) when is_binary(path) do
    # Use a process-local accumulator the IO step flushes at end-of-run.
    # Keeping a file open across the mutation phase introduces a leak
    # surface; building up iodata in the process dictionary is the
    # simplest, contention-free shape.
    fn iodata ->
      acc = Process.get(:mutagen_stream_buffer, [])
      Process.put(:mutagen_stream_buffer, [acc, iodata])
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

  @doc false
  # Internal seam exposed so tests can directly assert on the render
  # path's `Macro.to_string/1` call count per `mutagen.json_schema.r12`.
  # The function is `@doc false` and prefixed with `__` to signal it is
  # not part of the public Mix task API; calling it from outside the
  # test suite is unsupported.
  def __render_result__(r), do: render_result(r)

  defp render_result(r) do
    # Per `mutagen.json_schema.r12`: compute `Macro.to_string/1` of the
    # original AST exactly once per result and alias the same binary
    # into both `before` and `before_source`. The verbatim source-slice
    # contract documented in `lib/mutagen_ex/ast_cache.ex` (use of
    # `source_text` for `{line, column, end_line, end_column}` slicing)
    # is a follow-up — for now the two fields share the same
    # `Macro.to_string` output, which is the v1 status quo minus the
    # double-compute waste.
    before_binary = Macro.to_string(r.original_ast)

    %{
      id: r.id,
      file: r.file,
      line: r.line,
      column: r.column,
      mutator: r.mutator,
      before: before_binary,
      before_source: before_binary,
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
  #
  # When `--stream` is set and `--json <path>` is also set, the
  # JsonStreamer has accumulated per-site lines in
  # `Process.get(:mutagen_stream_buffer)`. We flush that buffer FIRST,
  # then append the aggregate document — both go to the same file in
  # a single `File.write!/2` so the file is created atomically (no
  # partial-write race observable to a watcher tailing the file).
  @spec default_io(iodata(), non_neg_integer(), Config.t() | nil) :: no_return()
  def default_io(iodata, exit_code, config) do
    case config do
      %Config{json_path: nil, stream: true} ->
        # `--stream` without `--json`: NDJSON lines have already been
        # written incrementally to stdout via `:standard_io`. The
        # final aggregate document follows on the same stream so a
        # tailing consumer sees N+2 NDJSON values followed by the
        # multi-line aggregate.
        IO.write(iodata)

      %Config{json_path: nil} ->
        IO.write(iodata)

      %Config{json_path: path, stream: true} when is_binary(path) ->
        buffered = Process.get(:mutagen_stream_buffer, [])
        Process.delete(:mutagen_stream_buffer)
        File.write!(path, [buffered, iodata])

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
