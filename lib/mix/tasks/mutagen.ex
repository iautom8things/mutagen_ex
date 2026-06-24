defmodule Mix.Tasks.Mutagen do
  @shortdoc "Run mutation testing against a scope, gated by cited tests"

  @moduledoc """
  # mix mutagen

  ## Synopsis

      mix mutagen --scope <target> --tests <target> [--timeout-ms N] [--seed N] [--json PATH] [--unsafe-json-outside-project] [--max-sites N] [--budget-ms N] [--max-concurrency N]

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
    * `--max-concurrency <int>` — per-site mutation dispatch cap. Default
      `1` (fully serial, v1.0-equivalent). Values greater than `1` are
      EXPERIMENTAL and emit a one-shot stderr warning because real
      ExUnit/:cover backends can produce incorrect kill/survive
      classification and corrupted coverage under parallel dispatch.

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
    * **`--max-concurrency > 1` is experimental.** Parallel dispatch shares
      ExUnit.Server, the Code.Server, and `:cover` across per-site tasks.
      It can produce incorrect kill/survive classification and corrupted
      coverage on real ExUnit/:cover backends; the safe path is the
      default, `--max-concurrency 1`.
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
  **module atom** the task uses instead of a hard-coded call, so every
  error path AND the happy path can be unit-tested by injecting a stub
  module that captures its arguments and returns canned shapes.

  Per bw mutagen-wrd.33 (closes F9), the 11 production phase keys carry
  module atoms (not `{module, function}` tuples). The Mix task calls
  `mod.callback(args)` directly; the callback for each slot is defined
  by a dedicated behaviour under `MutagenEx.Pipeline.*Facade`.

  The keys correspond to the orchestration stages of
  `mutagen.mutation_pipeline`:

    * `:cli` — `mod.parse(argv)` (`MutagenEx.Pipeline.CliFacade`,
      default `MutagenEx.CLI`).
    * `:scope` — `mod.resolve(target, opts)`
      (`MutagenEx.Pipeline.ScopeFacade`, default
      `MutagenEx.ScopeResolver`).
    * `:tests` — `mod.resolve(tests, opts)`
      (`MutagenEx.Pipeline.TestsFacade`, default
      `MutagenEx.TestSelector`).
    * `:ast_cache` — `mod.load(files, opts)`
      (`MutagenEx.Pipeline.AstCacheFacade`, default
      `MutagenEx.AstCache`).
    * `:coverage` — `mod.run(input)`
      (`MutagenEx.Pipeline.CoverageFacade`, default
      `MutagenEx.CoverageRunner`).
    * `:enumerator` — `mod.enumerate(cache, scope, covered, opts)`
      (`MutagenEx.Pipeline.EnumeratorFacade`, default
      `MutagenEx.MutationEnumerator`).
    * `:baseline` — `mod.run(input)`
      (`MutagenEx.Pipeline.BaselineFacade`, default
      `MutagenEx.Baseline`).
    * `:mutation` — `mod.run(input)`
      (`MutagenEx.Pipeline.MutationFacade`, default
      `MutagenEx.MutationRunner`).
    * `:reporter_ok` — `mod.emit_report(report)`
      (`MutagenEx.Pipeline.ReporterOkFacade`, default
      `MutagenEx.JsonReporter`).
    * `:reporter_error` — `mod.emit_error(report, reason)`
      (`MutagenEx.Pipeline.ReporterErrorFacade`, default
      `MutagenEx.JsonReporter`).
    * `:io` — `mod.emit(iodata, exit_code, Config.t())` sink for the
      final document (`MutagenEx.Pipeline.IoFacade`, default
      `MutagenEx.Pipeline.DefaultIo` — writes to stdout or
      `Config.json_path` and halts the VM with `exit_code`).

  S1 shipped a two-key legacy shape (`:reporter`, `:pipeline`) for
  early CLI testing. Those keys carry `{module, function}` tuples and
  route through the legacy code path (`run_legacy/2`), which uses
  `apply/3` to dispatch — that is the explicit back-compat fallback
  carve-out of `mutagen-wrd.33`'s "no apply/3 in the Mix task"
  contract.
  """
  @type dispatch :: %{
          optional(:cli) => module(),
          optional(:scope) => module(),
          optional(:tests) => module(),
          optional(:ast_cache) => module(),
          optional(:coverage) => module(),
          optional(:enumerator) => module(),
          optional(:baseline) => module(),
          optional(:mutation) => module(),
          optional(:reporter_ok) => module(),
          optional(:reporter_error) => module(),
          optional(:io) => module(),
          optional(:reporter) => {module(), atom()},
          optional(:pipeline) => {module(), atom()}
        }

  @impl Mix.Task
  def run(argv) do
    ensure_runtime()
    run(argv, default_dispatch())
  end

  @doc false
  @spec __ensure_runtime__(module()) :: :ok | {:aborted, :runtime_load_failed, Report.t()}
  def __ensure_runtime__(io_mod \\ MutagenEx.Pipeline.DefaultIo), do: ensure_runtime(io_mod)

  defp ensure_runtime do
    ensure_runtime(MutagenEx.Pipeline.DefaultIo)
  end

  defp ensure_runtime(io_mod) do
    Mix.Task.run("loadpaths")
    Mix.Task.run("compile")

    case ensure_mutagen_started() do
      {:ok, _apps} ->
        ExUnit.start(autorun: false)
        :ok

      {:error, _reason} = error ->
        handle_runtime_load_failure(error, io_mod)
    end
  end

  defp ensure_mutagen_started do
    case runtime_ensure_all_started() do
      {:ok, _apps} = ok ->
        ok

      {:error, _reason} = error ->
        maybe_repair_archive_context(error)
    end
  end

  defp maybe_repair_archive_context(error) do
    if archive_context_failure?(error) do
      # Primary repair uses Mix's documented intent-level archive path helper;
      # the ebin scan is a defensive fallback if archive appending regresses.
      Mix.Local.append_archives()

      case runtime_ensure_all_started() do
        {:ok, _apps} = ok ->
          ok

        {:error, _reason} = retry_error ->
          _ = add_first_mutagen_archive_ebin()
          retry_after_archive_scan(retry_error)
      end
    else
      error
    end
  end

  defp retry_after_archive_scan(previous_error) do
    case runtime_ensure_all_started() do
      {:ok, _apps} = ok -> ok
      {:error, _reason} -> previous_error
    end
  end

  defp runtime_ensure_all_started do
    case Process.get(:mutagen_ensure_runtime_force_failure) do
      nil ->
        Application.ensure_all_started(:mutagen_ex)

      fun when is_function(fun, 0) ->
        fun.()

      [result | rest] ->
        Process.put(:mutagen_ensure_runtime_force_failure, rest)
        result

      result ->
        result
    end
  end

  defp archive_context_failure?({:error, {:mutagen_ex, :non_existing}}), do: true
  defp archive_context_failure?({:error, {:mutagen_ex, {:non_existing, _}}}), do: true
  defp archive_context_failure?({:error, {:mutagen_ex, {_, ~c"mutagen_ex.app"}}}), do: true
  defp archive_context_failure?(_), do: false

  defp add_first_mutagen_archive_ebin do
    Mix.path_for(:archives)
    |> Path.join("*")
    |> Path.wildcard()
    |> Enum.find_value(:not_found, fn archive ->
      ebin = Mix.Local.archive_ebin(archive)
      app_file = Path.join(to_string(ebin), "mutagen_ex.app")

      if File.exists?(app_file) do
        :code.add_pathz(to_charlist(ebin))
      else
        false
      end
    end)
  end

  defp handle_runtime_load_failure(error, io_mod) do
    report = %Report{
      base_report(nil)
      | details: %{
          message:
            "mutagen_ex could not start from the installed archive after repairing code paths. " <>
              "Reinstall it with `mix archive.uninstall mutagen_ex && mix archive.install <ez>` " <>
              "or add `{:mutagen_ex, ...}` as a dependency, then retry. Last error: " <>
              inspect(error)
        }
    }

    {iodata, code} = MutagenEx.JsonReporter.emit_error(report, :runtime_load_failed)
    io_mod.emit(iodata, code, %Config{scopes: [], tests: [], json_path: nil})

    {:aborted, :runtime_load_failed,
     %Report{report | aborted: true, abort_reason: "runtime_load_failed"}}
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
    cli_mod = Map.fetch!(dispatch, :cli)

    case cli_mod.parse(argv) do
      {:ok, config} ->
        # Legacy `:pipeline` slot is a `{module, function}` tuple — this
        # is the explicit back-compat fallback path mutagen-wrd.33's
        # Verification carves out from the "no apply/3" contract.
        {pipeline_mod, pipeline_fun} = Map.fetch!(dispatch, :pipeline)
        apply(pipeline_mod, pipeline_fun, [config])
        :ok

      {:error, reason, details} ->
        # Same back-compat carve-out as `:pipeline` above.
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
    # The per-site progress reporter (when enabled) rides the runner's
    # `:on_site_completed` callback — see `phase_mutation/7`. We decide
    # enablement once at entry (before phase_cli parses) so the same
    # reporter spans the whole mutation phase; `--no-progress` skips it
    # outright. A full `--progress=auto` decision happens in
    # `MutagenEx.Progress.enabled?/1`.
    progress_reporter = build_progress_reporter(argv)

    case do_pipeline(argv, dispatch, progress_reporter) do
      {:ok, report, config} ->
        maybe_emit_stream_end(report, config)
        emit_success(report, config, dispatch)

      {:abort, %Report{} = report, config, reason, details} ->
        maybe_emit_stream_end(
          %Report{report | aborted: true, abort_reason: Atom.to_string(reason)},
          config
        )

        emit_abort(report, config, reason, details, dispatch)
    end
  end

  @doc false
  # Test seam for the per-site progress reporter. Production code calls
  # `build_progress_reporter/1`, which resolves the `--no-progress` /
  # TTY-auto decision from argv. Tests call this directly to pin the
  # reporter's behavior (index counter, payload→meta projection,
  # rendering) without depending on whether the test VM's stderr is a
  # TTY. `mode` is the resolved `MutagenEx.Progress` mode (`:on` |
  # `:off` | `:auto`); `device` is the I/O sink the rendered line is
  # written to (production: `:stderr`).
  @spec __build_progress_reporter__(:on | :off | :auto, IO.device()) ::
          (term(), non_neg_integer() -> :ok) | nil
  def __build_progress_reporter__(mode, device \\ :stderr) do
    if MutagenEx.Progress.enabled?(mode) do
      counter = :counters.new(1, [:atomics])

      fn payload, total ->
        :counters.add(counter, 1, 1)
        index = :counters.get(counter, 1)
        meta = progress_meta(payload, index, total)
        MutagenEx.Progress.report(meta, device)
      end
    else
      nil
    end
  end

  # Argv-scan for `--no-progress` to decide enablement. We do this at
  # entry (before phase_cli parses) so the reporter is composed over the
  # entire mutation phase; if the user passed `--no-progress` we never
  # build a reporter. Returns either `nil` (no progress) or a
  # 2-arity function `(payload, total)` the mutation phase composes into
  # the runner's `:on_site_completed` callback. The reporter is
  # stateful: it carries a running site index across calls via its
  # closed-over counter, so `MutagenEx.Progress.report/2` gets a
  # `[index/total]` prefix without the runner having to thread
  # index/total through the callback payload.
  defp build_progress_reporter(argv) do
    progress =
      cond do
        "--no-progress" in argv -> :off
        true -> :auto
      end

    __build_progress_reporter__(progress)
  end

  # Build the `MutagenEx.Progress.report/2` meta map from an
  # `:on_site_completed` callback payload. `{:result, map}` carries the
  # site's `:status`; `{:compile_error, entry}` is always a
  # `:compile_error` status.
  defp progress_meta({:result, result}, index, total) do
    %{
      index: index,
      total: total,
      status: Map.get(result, :status, :unknown),
      file: Map.get(result, :file, ""),
      line: Map.get(result, :line, 0),
      mutator: Map.get(result, :mutator, :unknown),
      site_id: Map.get(result, :id)
    }
  end

  defp progress_meta({:compile_error, entry}, index, total) do
    %{
      index: index,
      total: total,
      status: :compile_error,
      file: Map.get(entry, :file, ""),
      line: Map.get(entry, :line, 0),
      mutator: Map.get(entry, :mutator, :unknown),
      site_id: Map.get(entry, :id)
    }
  end

  defp maybe_emit_stream_end(%Report{} = report, %Config{stream: true} = config) do
    sink = stream_sink(config, %{})
    MutagenEx.JsonStreamer.emit_end(sink, report)
  end

  defp maybe_emit_stream_end(_, _), do: :ok

  defp do_pipeline(argv, dispatch, progress_reporter) do
    report0 = base_report(nil)

    with {:ok, config} <- phase_cli(argv, dispatch),
         report1 = with_meta(report0, config),
         {:ok, config} <- phase_json_path(config, report1),
         {:ok, scope_records} <- phase_scope(config, dispatch, report1),
         report2 = %Report{report1 | scope: scope_records},
         {:ok, test_filter} <- phase_tests(config, dispatch, report2),
         report3 = %Report{report2 | tests: test_filter_to_wire(test_filter)},
         {:ok, ast_cache} <- phase_ast_cache(scope_records, test_filter, dispatch, report3),
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
             report5,
             progress_reporter
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
    mod = Map.fetch!(dispatch, :cli)

    case mod.parse(argv) do
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
        {:abort, report, %Config{config | json_path: nil}, reason, details}
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
    mod = Map.fetch!(dispatch, :scope)

    result =
      Enum.reduce_while(scopes, {:ok, []}, fn target, {:ok, acc} ->
        case mod.resolve(target, []) do
          {:ok, records} ->
            {:cont, {:ok, [records | acc]}}

          {:error, reason, details} ->
            partial = %Report{report | scope: :lists.append(:lists.reverse(acc))}

            {:halt, {:abort, partial, config, reason, Map.put_new(details, :target, target)}}
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
    mod = Map.fetch!(dispatch, :tests)

    case mod.resolve(tests, []) do
      {:ok, filter} ->
        {:ok, filter}

      {:error, %{reason: reason} = details} ->
        {:abort, report, config, reason, details}

      {:error, reason, details} when is_atom(reason) ->
        {:abort, report, config, reason, details}
    end
  end

  # Post-`.25.3` (F18 / F40): the AST cache now covers BOTH scope files
  # AND the cited test files in a single load step. Baseline's
  # async-module detection (see baseline.ex) consumes the cached test-file
  # ASTs directly so it does not re-read those files from disk.
  #
  # The flat `files` list is the union of scope files + test files (deduped).
  # The `categories` opt is input-only diagnostic metadata per
  # mutagen.coverage.r9 — the cache entry shape stays
  # `{Macro.t(), String.t()}`. There is no category tag in entries and no
  # `files_by_category/2` consumer API (decision: lookups stay by file path).
  #
  # The test set is `test_filter.files` (the resolved cited test files
  # from phase_tests), NOT the full `test/**/*.exs` tree (F19 was
  # explicitly descoped — see mutagen.decision.f19_descoped).
  defp phase_ast_cache(scope_records, test_filter, dispatch, report) do
    mod = Map.fetch!(dispatch, :ast_cache)

    scope_files = scope_records |> Enum.map(& &1.file) |> Enum.uniq()
    test_files = test_filter.files |> Enum.uniq()
    files = (scope_files ++ test_files) |> Enum.uniq()

    opts = [categories: %{scope: scope_files, test: test_files}]

    case mod.load(files, opts) do
      {:ok, cache} ->
        {:ok, cache}

      {:error, reason, details} ->
        {:abort, report, nil, reason, details}
    end
  end

  defp phase_coverage(%Config{seed: seed} = config, scope_records, test_filter, dispatch, report) do
    mod = Map.fetch!(dispatch, :coverage)

    in_scope_modules =
      scope_records
      |> Enum.map(&{&1.module, &1.file})
      |> Enum.uniq()

    # `CoverageRunner.run/1` re-registers each cited test module with
    # `ExUnit.Server` before its own `ExUnit.run/0`, so a second
    # `mix mutagen` invocation in the same BEAM that cites a
    # previously-cited test file still sees the cited modules in the
    # server's registry (the prior `ExUnit.run/0` drained them and
    # `Code.require_file/1` is one-shot per path). Without this
    # payload, coverage would silently record zero covered lines on
    # the second invocation and downstream enumeration would emit
    # zero sites (mutagen-wrd.38). See
    # `mutagen.mutation_pipeline.r10`.
    input = %{
      seed: seed,
      in_scope_modules: in_scope_modules,
      test_filter: test_filter,
      test_modules: MutagenEx.TestModuleDiscovery.discover(test_filter.files)
    }

    case mod.run(input) do
      {:ok, result} ->
        {:ok, result}

      {:error, reason, details} ->
        {:abort, report, config, reason, details}
    end
  end

  # `--max-sites` flows in here so an over-budget enumeration aborts
  # before the runner even starts. The enumerator returns
  # `{:error, :too_many_sites, details}` when the produced sites would
  # exceed `Config.max_sites`; that becomes an abort-JSON document so
  # the user gets a structured "your scope is too large, narrow it"
  # signal rather than an OOM.
  defp phase_enumerator(
         %Config{max_sites: max_sites} = config,
         ast_cache,
         scope_records,
         coverage_result,
         dispatch,
         %Report{} = report
       ) do
    mod = Map.fetch!(dispatch, :enumerator)

    covered_lines = coverage_result.covered_lines

    case mod.enumerate(ast_cache, scope_records, covered_lines, max_sites: max_sites) do
      %{sites: _, skipped: _, warnings: _} = enum_result ->
        {:ok, enum_result}

      {:error, :too_many_sites, details} ->
        {:abort, report, config, :too_many_sites, details}
    end
  end

  defp phase_baseline(%Config{seed: seed} = config, test_filter, dispatch, %Report{} = report) do
    mod = Map.fetch!(dispatch, :baseline)

    # `Baseline.run/1` re-registers each cited test module with
    # `ExUnit.Server` before its own `ExUnit.run/0`, because the
    # coverage phase that ran just before it consumed the registered
    # modules and `Code.require_file/1` is one-shot per path. Without
    # this payload, baseline would silently run zero tests and miss
    # every red baseline (mutagen-wrd.37). See
    # `mutagen.mutation_pipeline.r1`.
    input = %{
      seed: seed,
      test_filter: test_filter,
      test_modules: MutagenEx.TestModuleDiscovery.discover(test_filter.files)
    }

    case mod.run(input) do
      {:ok, result} ->
        {:ok, result}

      {:error, :baseline_red, details} ->
        # r1: baseline failures populate `baseline` on the abort report.
        partial_baseline = %{
          "passed" => Map.get(details, :passed, 0),
          "failed" => Map.get(details, :failed, length(Map.get(details, :failures, []))),
          "failures" => Enum.map(Map.get(details, :failures, []), &failure_to_wire/1)
        }

        partial = %Report{report | baseline: partial_baseline}

        {:abort, partial, config, :baseline_red, details}

      {:error, reason, details} ->
        {:abort, report, config, reason, details}
    end
  end

  defp phase_mutation(
         %Config{seed: seed, timeout_ms: timeout_ms, budget_ms: budget_ms} = config,
         test_filter,
         ast_cache,
         sites,
         scope_records,
         dispatch,
         report,
         progress_reporter
       ) do
    mod = Map.fetch!(dispatch, :mutation)

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
    # The `:on_site_completed` seam fires once per completed site (in
    # input order, both `--max-concurrency 1` and `> 1`). It is the
    # single per-site observation point: when `--stream` is set it
    # emits one NDJSON line per site to the same sink the final
    # document goes to, and when progress is enabled (TTY auto-detect,
    # not `--no-progress`) it draws the per-site progress feed on
    # stderr. The two consumers are independent and compose here — a
    # run can stream, show progress, both, or neither.
    site_sink = stream_sink(config, dispatch)

    if config.stream do
      MutagenEx.JsonStreamer.emit_start(
        site_sink,
        length(sites),
        (report.meta || %{})
        |> Map.put_new(:tool_version, "0.0.0-dev")
      )
    end

    total = length(sites)

    stream_fn =
      if config.stream do
        fn
          {:result, result_map} -> MutagenEx.JsonStreamer.emit_result(site_sink, result_map)
          {:compile_error, entry} -> MutagenEx.JsonStreamer.emit_compile_error(site_sink, entry)
        end
      else
        fn _ -> :ok end
      end

    on_site_completed =
      fn payload ->
        stream_fn.(payload)
        if progress_reporter, do: progress_reporter.(payload, total)
        :ok
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

    case mod.run(input) do
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
    # Per `mutagen.json_schema.r4` + r12: `before` is always the
    # `Macro.to_string(original_ast)` output (computed exactly once).
    # `before_source` is a verbatim slice of `source_text` when the
    # enumerator provided `end_line`/`end_column` AND a `source_text`
    # was threaded through by the runner; otherwise it aliases the
    # same binary as `before` (the legacy / fallback path).
    #
    # The slice path uses byte indexing — no additional
    # `Macro.to_string/1` call — so the `2 * R` cap from r12 holds
    # regardless of which path each site takes.
    before_binary = Macro.to_string(r.original_ast)
    before_source = render_before_source(r, before_binary)

    %{
      id: r.id,
      file: r.file,
      line: r.line,
      column: r.column,
      mutator: r.mutator,
      before: before_binary,
      before_source: before_source,
      after: Macro.to_string(r.mutated_ast),
      status: r.status,
      tainted_predecessors: r.tainted_predecessors,
      warnings: r.warnings
    }
  end

  # `before_source` resolution:
  #   1. If the result lacks `end_line` / `end_column` (legacy callers,
  #      bare-literal sites, macro-expanded forms): alias `before`.
  #   2. If no `source_text` was threaded through: alias `before`.
  #   3. If we can derive a slice-start position from `original_ast`
  #      (the leftmost descendant's `{line, column}`): slice
  #      `source_text` between `{start_line, start_column}` and
  #      `{end_line, end_column}` (end-exclusive).
  #   4. Otherwise: alias `before`.
  defp render_before_source(r, before_binary) do
    end_line = Map.get(r, :end_line)
    end_column = Map.get(r, :end_column)
    source_text = Map.get(r, :source_text)

    cond do
      is_nil(end_line) or is_nil(end_column) ->
        before_binary

      not is_binary(source_text) ->
        before_binary

      true ->
        case leftmost_descendant_position(r.original_ast) do
          {start_line, start_column}
          when is_integer(start_line) and is_integer(start_column) ->
            case slice_source(source_text, start_line, start_column, end_line, end_column) do
              {:ok, slice} -> slice
              :error -> before_binary
            end

          _ ->
            before_binary
        end
    end
  end

  # Find the leftmost descendant's `{line, column}` of an AST node.
  # For most nodes the leftmost descendant is in `args`; if no
  # descendant carries position metadata, fall back to the node's
  # own meta. Returns `{line, column}` or `nil`.
  defp leftmost_descendant_position(ast) do
    case do_leftmost(ast) do
      {line, column} when is_integer(line) and is_integer(column) -> {line, column}
      _ -> nil
    end
  end

  defp do_leftmost({_form, meta, args}) when is_list(meta) do
    # Prefer a descendant's position (the leftmost child whose
    # leftmost descendant carries meta). Fall back to this node's own
    # meta only when no descendant qualifies.
    case do_leftmost_children(args) do
      {line, col} when is_integer(line) and is_integer(col) ->
        # If THIS node's meta is to the left of the descendant's
        # (e.g. an operator that starts at col 24 but whose child
        # is at col 22 — actually impossible by parser, but the
        # general principle: take the leftmost position).
        own =
          case {Keyword.get(meta, :line), Keyword.get(meta, :column)} do
            {l, c} when is_integer(l) and is_integer(c) -> {l, c}
            _ -> nil
          end

        case own do
          nil -> {line, col}
          {own_line, own_col} -> earlier({own_line, own_col}, {line, col})
        end

      _ ->
        case {Keyword.get(meta, :line), Keyword.get(meta, :column)} do
          {l, c} when is_integer(l) and is_integer(c) -> {l, c}
          _ -> nil
        end
    end
  end

  defp do_leftmost(_), do: nil

  defp do_leftmost_children(nil), do: nil

  defp do_leftmost_children(args) when is_list(args) do
    Enum.reduce_while(args, nil, fn child, acc ->
      case do_leftmost(child) do
        nil -> {:cont, acc}
        pos -> {:halt, pos}
      end
    end)
  end

  defp do_leftmost_children(_), do: nil

  # The earlier of two positions (smaller line first; same line: smaller column).
  defp earlier({l1, c1}, {l2, c2}) do
    cond do
      l1 < l2 -> {l1, c1}
      l1 > l2 -> {l2, c2}
      c1 <= c2 -> {l1, c1}
      true -> {l2, c2}
    end
  end

  # Slice `source_text` between `{start_line, start_column}` (inclusive,
  # 1-based) and `{end_line, end_column}` (exclusive, 1-based). Returns
  # `{:ok, slice}` on success, `:error` if the indices are out of range.
  # Columns count UTF-8 codepoints (matching how Elixir's tokenizer
  # populates `:column`).
  defp slice_source(source_text, start_line, start_column, end_line, end_column)
       when is_binary(source_text) and is_integer(start_line) and is_integer(start_column) and
              is_integer(end_line) and is_integer(end_column) do
    lines = String.split(source_text, "\n", trim: false)

    try do
      cond do
        start_line < 1 or end_line < 1 ->
          :error

        start_line > end_line ->
          :error

        start_line == end_line ->
          line = Enum.at(lines, start_line - 1)

          if is_binary(line) and end_column > start_column do
            # Convert from 1-based inclusive `start_column` and 1-based
            # exclusive `end_column` to byte indices on the line.
            len = end_column - start_column
            slice = slice_codepoints(line, start_column - 1, len)
            {:ok, slice}
          else
            :error
          end

        true ->
          # Multi-line slice: take suffix of start_line from start_column,
          # all middle lines in full, prefix of end_line up to end_column.
          start_line_text = Enum.at(lines, start_line - 1)
          end_line_text = Enum.at(lines, end_line - 1)

          middle =
            if end_line - start_line >= 2 do
              Enum.slice(lines, start_line, end_line - start_line - 1)
            else
              []
            end

          if is_binary(start_line_text) and is_binary(end_line_text) do
            start_suffix = slice_codepoints_tail(start_line_text, start_column - 1)
            end_prefix = slice_codepoints(end_line_text, 0, end_column - 1)

            middle_iodata =
              case middle do
                [] -> []
                _ -> [Enum.intersperse(middle, "\n"), "\n"]
              end

            iodata = [start_suffix, "\n", middle_iodata, end_prefix]
            {:ok, IO.iodata_to_binary(iodata)}
          else
            :error
          end
      end
    rescue
      _ -> :error
    end
  end

  defp slice_source(_, _, _, _, _), do: :error

  # Take `len` codepoints from `string` starting at codepoint index `start`.
  defp slice_codepoints(string, start, len) do
    string
    |> String.graphemes()
    |> Enum.slice(start, len)
    |> Enum.join()
  end

  defp slice_codepoints_tail(string, start) do
    string
    |> String.graphemes()
    |> Enum.drop(start)
    |> Enum.join()
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
    mod = Map.fetch!(dispatch, :reporter_ok)
    {iodata, code} = mod.emit_report(report)

    io_mod = Map.fetch!(dispatch, :io)
    io_mod.emit(iodata, code, config)
    :ok
  end

  defp emit_abort(%Report{} = report, config, reason, details, dispatch) do
    mod = Map.fetch!(dispatch, :reporter_error)
    report = %Report{report | details: details}
    {iodata, code} = mod.emit_error(report, reason)

    io_mod = Map.fetch!(dispatch, :io)
    io_mod.emit(iodata, code, config)

    {:aborted, reason, %Report{report | aborted: true, abort_reason: Atom.to_string(reason)}}
  end

  # ---------------------------------------------------------------------------
  # Defaults
  # ---------------------------------------------------------------------------

  @doc false
  # Exposed only for `run/1`. Tests pass a (partial) dispatch via
  # `run/2`; missing keys fall back here.
  #
  # Per bw mutagen-wrd.33 (F9), the 11 production phase keys carry
  # plain module atoms — the Mix task calls `mod.callback(args)`
  # directly. The two legacy keys (`:reporter`, `:pipeline`) keep the
  # `{module, function}` tuple shape; they route through
  # `run_legacy/2`, which is the explicit back-compat fallback the
  # Verification block carves out from the "no apply/3" contract.
  @spec default_dispatch() :: dispatch()
  def default_dispatch do
    %{
      cli: MutagenEx.CLI,
      scope: MutagenEx.ScopeResolver,
      tests: MutagenEx.TestSelector,
      ast_cache: MutagenEx.AstCache,
      coverage: MutagenEx.CoverageRunner,
      enumerator: MutagenEx.MutationEnumerator,
      baseline: MutagenEx.Baseline,
      mutation: MutagenEx.MutationRunner,
      reporter_ok: MutagenEx.JsonReporter,
      reporter_error: MutagenEx.JsonReporter,
      io: MutagenEx.Pipeline.DefaultIo,
      # S1 back-compat — only reached via the legacy code path
      # (`run_legacy/2`). These two keys still use `{module, function}`
      # tuples because pre-.33 tests depend on the legacy seam shape.
      reporter: {__MODULE__, :default_report_error},
      pipeline: {__MODULE__, :default_run_pipeline}
    }
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
