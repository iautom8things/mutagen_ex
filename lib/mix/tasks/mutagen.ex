defmodule Mix.Tasks.Mutagen do
  @shortdoc "Run mutation testing against a scope and selected tests"

  @moduledoc """
  # mix mutagen

  ## Synopsis

      MIX_ENV=test mix mutagen [--scope <target>] [--tests <target|auto>] [--since REF] [--site ID] [--summary PATH] [--summary-max N] [--no-escalate] [--escalate-max-files N] [--escalate-budget-ms N] [--timeout-ms N] [--no-fail-fast] [--seed N] [--json PATH] [--stream] [--no-progress] [--unsafe-json-outside-project] [--max-sites N] [--budget-ms N] [--max-concurrency N] [--no-host-app] [--no-test-alias] [--boot-timeout-ms N] [--no-source] [--include-host-output]

  Run mutation testing against one or more scope targets, judged by a chosen
  set of tests. The final JSON document goes to stdout or `--json <path>`.
  It lists every mutation and its outcome together with run metadata.

  ## Reading the summary

      MIX_ENV=test mix mutagen --since origin/main --summary mutagen.md --json mutagen.json

  The JSON and Markdown reports give advice for one run. Check first marks
  functions with only uncovered sites or with at least three evaluated
  high-confidence mutants and no kills. Worth a look lists remaining
  high-confidence survivors. Low-confidence survivors stay in the detailed
  results. Timeouts are counted as unevaluated.

  Copy a printed `--site <id>` command to rerun one site with wider
  automatic test discovery. Use the same checkout.

  ## Audit mode

      MIX_ENV=test mix mutagen --scope MyApp.Billing --tests auto --json billing.json --summary billing.md
      jq '.summary.by_function[]' billing.json
      find lib/my_app -name '*.ex' | while IFS= read -r file; do
        MIX_ENV=test mix mutagen --scope "$file" --tests auto --json "audit/$file.json" --summary "audit/$file.md"
      done
      find audit -name '*.json' -exec cat {} + | jq -rs 'sort_by(.summary.counts.kill_rate // 2)[] | [.summary.counts.kill_rate, ([.scope[].module] | join(", "))] | @tsv'

  ## Running in CI

  Check out full history (`fetch-depth: 0`). A shallow checkout aborts.
  Set `MUTAGEN_BASE` to the pull request's base commit.

      MIX_ENV=test mix mutagen --since "$MUTAGEN_BASE" --json mutagen.json --summary mutagen.md

  Append the Markdown to `$GITHUB_STEP_SUMMARY` when present and upload
  the JSON. Use `continue-on-error: true` for aborts. See the README for a GitHub Actions
  example. The unmapped list shows changed lines outside runtime mutation
  sites, including attributes and macros. Each run is advisory.

  ## Host test setup

  Use `MIX_ENV=test` or explicitly select a custom test environment.
  The task compiles test support, loads runtime config, and runs the host
  test alias entries before the test task. It then starts the host OTP
  application and requires `test_helper.exs` once from each configured
  `:test_paths` entry with ExUnit autorun disabled.

  Coverage, baseline, and each mutant use the helper's ExUnit options.
  Formatters run on each pass. The report is written before after-suite
  callbacks run. Each callback gets its own boot timeout. Cleanup errors
  and timeouts go to stderr. A call to `System.halt/1` in the helper
  prevents reporting.

  The default report contains source excerpts and structured facts. Host
  diagnostic bodies go to stderr. Abort documents include a fixed hint and
  the step, exception and location when available. Source excerpts may
  contain secrets committed in the repository. Pattern redaction of opted-in
  host diagnostics is best-effort.

  `--json PATH` is the guaranteed report channel. The file contains exactly
  one JSON document, or NDJSON with `--stream`, regardless of host output.

  Without `--json`, Mutagen writes the report to stdout and routes the
  `:user` device and known console logger handlers to stderr. The VM can
  write directly to file descriptor 1, including when an OTP logger
  handler crashes. In-process I/O routing cannot intercept those writes.
  Use `--json PATH` and `--summary PATH` in CI.

  Mix can also write to stdout before the task starts. Do not publish stderr.

  ## Flags

    * `--scope <target>` selects a file ending in `.ex`, a module, or
      `Module.Name.function/arity`. Repeat it to add targets. Required
      unless you use `--since` or `--site`.
    * `--tests <target>` selects a test file, a `file:line` reference, or
      `tag:<name>`. Repeat it to add targets, or use `auto` on its own.
      Required unless you use `--since` or `--site`.
    * `--summary <path>` writes Markdown to a file alongside the JSON report.
      The files must have distinct paths. As with `--json`, the path must stay
      within the project root unless `--unsafe-json-outside-project` is set.
      Use a filename instead of `-`.
    * `--summary-max <int>` caps the Worth a look list. Default 5, minimum 0.
    * `--site <id>` selects one report site. It defaults to automatic tests.
    * `--since <ref>` plans the runtime mutations touched since the merge
      base with the given ref. `--scope` intersects the diff when supplied.
      Test selection defaults to `auto`.
    * `--tests auto` selects conventional test files and, with `--since`,
      changed test files. It searches for more tests if mutants survive.
    * `--no-escalate` disables discovery after the first test selection.
    * `--escalate-max-files <int>` caps files per function in each pass. Default 20.
    * `--escalate-budget-ms <int>` limits time spent on the extra passes. Default
      120000. Zero removes the escalation time limit.
    * `--boot-timeout-ms <int>` sets the deadline for host setup after
      compilation and the deadline for each cleanup callback. Each
      coverage and baseline pass gets the greater of this timeout and
      ten times `--timeout-ms`. Default `300000`.
    * `--no-source` omits site source excerpts, file and function from
      aggregate and stream results and compile errors. Scope, test and
      coverage paths, module names and source-derived IDs remain.
    * `--include-host-output` includes captured compiler and test stderr
      and abort messages after best-effort redaction and truncation.
    * `--no-test-alias` skips the host test alias pre-steps. Mutagen ignores
      the arguments on the `test` entry and the return values of alias
      functions. It warns if the alias has entries and no `test` entry.
    * `--timeout-ms <int>` overrides the per-mutant deadline in milliseconds.
      By default the deadline is five times the baseline duration, with a
      5000 ms floor. Mutagen warns if a requested timeout is shorter than
      the baseline.
    * `--no-fail-fast` runs the full cited suite for each mutant.
      By default, the mutation phase
      stops executing tests on the first failure. A failure recorded
      before the deadline kills the mutant even if the full suite
      would time out. Baseline and coverage have no failure cap.
      The JSON field `meta.fail_fast` records the mode and defaults to
      `true` on argument errors.
      Survivor and kill equivalence assumes the tests run independently.
      Tests that set up or clean up state for other tests depend on
      ExUnit's ordering when the seed changes. Skipping one can change
      later mutants' verdicts, warnings, and taint, even when a later
      mutant runs every test. Use `--no-fail-fast` for these suites.

      After cited files load, Mutagen sets the seed, serial execution,
      failure cap and resolved filters. It keeps host formatters,
      adds its own when collecting failures and restores the host
      settings after each phase. Other host options stay active.
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
    * `--stream` emits per-site NDJSON lines with `start` and `end` envelopes
      on the JSON sink. The last line is the aggregate document without a
      `kind` field.
    * `--no-progress` suppresses the human-readable progress feed on stderr.
      By default, the feed appears when stderr is a TTY.
    * `--max-sites <int>` — upper bound on enumerated mutation sites
      for one run. Default `10000`. The enumerator aborts with
      `abort_reason: "too_many_sites"` before the runner starts when the cap is
      exceeded; narrow `--scope` (or raise the cap) to proceed.
    * `--budget-ms <int>` — aggregate wall-clock budget for the
      mutation phase, in milliseconds. Optional (default: unbounded;
      the per-site `--timeout-ms` is still enforced). When the budget
      elapses the runner stops dispatching new sites and emits a
      `truncated: true` partial report.
    * `--max-concurrency <int>` — per-site mutation dispatch cap. Default
      `1` (fully serial, v1.0-equivalent). Values greater than `1` are
      experimental and add warnings to the report and stderr because real
      ExUnit/:cover backends can produce incorrect kill/survive
      classification and corrupted coverage under parallel dispatch. The
      report records the limit as `meta.max_concurrency`.
    * `--no-host-app` — skip starting the host OTP application in the
      runtime preamble. Reserved for self-test sandboxes and libraries
      that intentionally need a minimal boot; the default is to start
      the host app so Repo/Sandbox, PubSub, Mox, and supervised test
      support are available. Runtime config and the helper still load when
      the app is skipped.

  ## Caps

    * `--scope` and `--tests` each accept at most 100 occurrences. Excess
      is refused at parse time with `abort_reason: "too_many_targets"`.
    * `--max-sites` caps enumerated mutation sites (default 10_000).
    * `--budget-ms` (optional) caps aggregate wall-clock for the
      mutation phase. The per-site `--timeout-ms` still applies.

  ## Examples

      # Single file scope, single test file
      MIX_ENV=test mix mutagen --scope lib/foo.ex --tests test/foo_test.exs

      # Multiple scopes, tag-based tests, custom timeout
      MIX_ENV=test mix mutagen --scope MyApp.Foo --scope lib/bar.ex \\
                  --tests tag:fast --timeout-ms 10000

      # Module-and-function scope, deterministic seed, redirected output
      MIX_ENV=test mix mutagen --scope MyApp.Foo.bar/1 --tests test/foo_test.exs \\
                  --seed 42 --json out/mutagen.json

  ## Constraints

    * Tests run **serially** (`max_cases: 1`) in every phase. There is no
      `--parallel` flag in v1 (see
      `mutagen.decision.serial_execution_and_seed`).
    * `--seed` controls **ExUnit test ordering** only. Mutation enumeration
      order is independent of the seed.
    * `mutagen_ex` runs **in-process** (same BEAM as your suite); see
      Caveats for the consequences (state drift, no self-mutation).

  Requires Elixir 1.18.0 or later and Erlang/OTP 27 or later.

  ## Exit Codes

    * `0` means Mutagen wrote a report, including incomplete runs and runs
      with surviving mutants.
    * `2` means Mutagen aborted and wrote an error document to stdout or
      `--json <path>`. The string field `abort_reason` identifies the error.

  A host callback calling `System.halt/1` decides the exit code. During
  after-suite cleanup it can leave a completed report with `aborted: false`
  and a non-zero exit.

  ## JSON Schema Pointer

  Each aggregate result and NDJSON `"result"` line carries `confidence`.
  The rating applies to the whole mutator. `with_swap`, `pipeline` and
  `guard_drop` rate low. The rest rate high. Both levels count toward
  aggregate totals and the kill rate.

  The aggregate's `meta.timings_ms` records elapsed time for boot, coverage,
  baseline, mutation and the full run. When comparing otherwise identical
  reports, exclude this field.

  See the README for examples from the CLI and
  `.spec/specs/json_schema.spec.md` for the schema contract.

  A survivor means “the tests you selected miss it”. First rerun with a
  wider `--tests` selection before writing a test.

  ## Known Caveats

    * **State drift on `use SomeModule`.** Modules using compile-time DSLs
      can drift between baseline and mutation runs; the JSON `warnings`
      array names the affected modules.
    * **Macro mutation slowdown.** Mutations inside macro-heavy modules
      recompile dependents; expect longer per-site runs.
    * **Equivalent mutants.** Some mutations are semantically equivalent
      to the original; they survive every test by definition. This is a
      known limit of mutation testing, not a tool bug.
    * **Mutation IDs use scheme 2.** Formatting and unrelated edits preserve
      IDs when the file path, enclosing definition, normalized expression,
      and occurrence among identical sites stay the same. Both JSON and
      NDJSON use report schema version `"2"`. IDs and reports from earlier
      versions cannot be compared with version 2. Compare the schema, ID
      scheme, and Elixir and OTP versions before comparing IDs. Formatter
      migrations (`mix format --migrate`) can rewrite the syntax and change IDs.
      When an identical expression is added earlier in a function, later IDs
      can shift. Persist and compare `function` and `before_source` alongside IDs.
    * **`--no-json` is not supported in v1.** Pretty terminal output is
      deferred to v1.1 (see `mutagen.decision.no_pretty_output_v1`); use
      `jq` for now.
    * **`--seed` controls ExUnit ordering only.** It does not seed mutation
      enumeration. Given the same source, enumeration order is stable.
    * **`--scope` colon syntax is unsupported.** `file.ex:Module` is rejected
      with `abort_reason: "colon_syntax_unsupported"` (see
      `mutagen.decision.scope_syntax_simplified`).
    * **Self-mutation is refused.** `--scope MutagenEx.*` or `Mix.Tasks.Mutagen`
      exits with `abort_reason: "self_mutation_refused"` (see
      `mutagen.decision.self_mutation_refused`).
    * **`--json` paths are canonicalised inside the project root.** Paths
      with `..` segments or NUL bytes exit with
      `abort_reason: "unsafe_json_path"` at parse time. Symlinks whose target
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
      this charset are refused with `abort_reason: "invalid_tag_name"` before any
      test resolution runs. This is the atom-table-DOS bound (see
      `mutagen.cli.r11`): CI loops like
      `mix mutagen --tests tag:$(uuidgen)` cannot grow the BEAM atom table.
    * **Caps on input and output volume.** `--scope` and `--tests` each
      accept at most 100 occurrences (`abort_reason: "too_many_targets"`).
      `--max-sites` caps enumerated mutation sites (default 10_000;
      `abort_reason: "too_many_sites"`). `--budget-ms` (optional) caps the
      aggregate mutation wall-clock and yields a `truncated: true`
      partial report when exhausted.
  """

  use Mix.Task

  alias MutagenEx.{ChangedRun, CLI, JsonReporter, MutationRunner}
  alias MutagenEx.Config
  alias MutagenEx.Runtime
  alias MutagenEx.Pipeline.Phases
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
          optional(:otp_release) => String.t(),
          optional(:elixir_version) => String.t(),
          optional(:project_root) => Path.t(),
          optional(:clock) => (atom() -> integer()),
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
    Mix.Local.append_archives()

    run_pipeline(argv, default_dispatch(), {:host, preload_report_modules()})
  end

  @report_modules [
    MutagenEx.JsonReporter,
    MutagenEx.JsonReporter.Report,
    MutagenEx.JsonStreamer,
    MutagenEx.ReportSummary,
    MutagenEx.MarkdownSummary,
    MutagenEx.JsonReporter.Redactor,
    MutagenEx.JsonReporter.Provenance,
    MutagenEx.Mutators,
    MutagenEx.Pipeline.DefaultIo,
    MutagenEx.Pipeline.Phases,
    MutagenEx.JsonReporter.Sanitizer,
    MutagenEx.JsonPath,
    MutagenEx.Test.RunGroup
  ]

  defp preload_report_modules do
    tool_ebin = __MODULE__ |> :code.which() |> Path.dirname()
    Enum.reduce_while(@report_modules, :ok, &preload_report_module(&1, &2, tool_ebin))
  end

  defp preload_report_module(module, :ok, tool_ebin) do
    beam = Path.join(tool_ebin, Atom.to_string(module))

    if :code.is_loaded(module) == {:file, to_charlist(beam <> ".beam")} do
      {:cont, :ok}
    else
      case :code.load_abs(to_charlist(beam)) do
        {:module, ^module} ->
          {:cont, :ok}

        {:error, reason} ->
          # Restore the tool code where possible so a late redefinition
          # cannot prevent the runtime-load error from being serialized.
          if reason == :not_purged and :code.soft_purge(module),
            do: :code.load_abs(to_charlist(beam))

          message =
            "mutagen_ex could not load #{inspect(module)} from #{tool_ebin} " <>
              "(#{inspect(reason)}). Reinstall mutagen_ex."

          {:halt, {:error, :runtime_load_failed, %{message: message, module: inspect(module)}}}
      end
    end
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
  defp run_pipeline(argv, dispatch, mode \\ :prepared) do
    started_at = System.monotonic_time()
    stdout = Process.group_leader()

    output = %{
      stdout: stdout,
      progress: build_progress_reporter(argv),
      root: Map.get_lazy(dispatch, :project_root, &File.cwd!/0),
      clock: Map.get(dispatch, :clock, fn _phase -> System.monotonic_time() end)
    }

    pipeline = fn ->
      argv
      |> prepare_pipeline(dispatch, output, mode)
      |> put_total_timing(started_at)
      |> emit_result(dispatch, output.stdout)
    end

    case mode do
      :prepared ->
        pipeline.()

      {:host, _preloaded} ->
        MutagenEx.Pipeline.DefaultIo.with_report_device(fn ->
          Runtime.route_default_logger()
          previous = Process.put(MutagenEx.JsonReporter.Sanitizer, [])

          try do
            pipeline.()
          after
            if previous,
              do: Process.put(MutagenEx.JsonReporter.Sanitizer, previous),
              else: Process.delete(MutagenEx.JsonReporter.Sanitizer)
          end
        end)
    end
  end

  defp emit_result({:cleanup, result, state}, dispatch, stdout) do
    emit_result(
      result,
      Map.put(dispatch, :cleanup, fn -> finish_suite(result, state) end),
      stdout
    )
  end

  defp emit_result({:ok, report, config}, dispatch, stdout) do
    report = %{report | summary: JsonReporter.summary(report)}

    case write_summary(report, config) do
      :ok ->
        maybe_emit_stream_end(report, config, stdout)
        emit_success(report, config, dispatch)

      {:error, _} ->
        emit_result(
          {:abort, %{report | summary: nil}, config, :summary_write_failed, %{}},
          dispatch,
          stdout
        )
    end
  end

  defp emit_result({:abort, %Report{} = report, config, reason, details}, dispatch, stdout) do
    maybe_emit_stream_end(
      %Report{report | aborted: true, abort_reason: Atom.to_string(reason)},
      config,
      stdout
    )

    write_abort_summary(report, config, reason, details)
    emit_abort(report, config, reason, details, dispatch)
  end

  defp write_abort_summary(report, %{summary_requested: path} = config, reason, details)
       when is_binary(path) and reason != :summary_write_failed do
    files = details[:failing_files] || []
    paths = if report.source, do: Enum.map(files, &JsonReporter.Sanitizer.clean/1), else: []
    red = %{count: length(files), files: paths}
    hint = JsonReporter.abort_hint(reason, details)
    document = MutagenEx.MarkdownSummary.render_abort(to_string(reason), hint, red)

    case MutagenEx.Pipeline.DefaultIo.write_summary(document, config) do
      :ok -> :ok
      {:error, _} -> IO.puts(:stderr, "warning: summary_write_failed")
    end
  end

  defp write_abort_summary(_report, _config, _reason, _details), do: :ok

  defp write_summary(_report, %{summary_path: nil}), do: :ok

  defp write_summary(report, config) do
    meta = JsonReporter.stream_meta_to_wire(report.meta, report)
    document = MutagenEx.MarkdownSummary.render(%{"meta" => meta, "summary" => report.summary})
    MutagenEx.Pipeline.DefaultIo.write_summary(document, config)
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

  defp maybe_emit_stream_end(
         %Report{stream_end: true} = report,
         %Config{stream: true} = config,
         stdout
       ) do
    MutagenEx.JsonStreamer.emit_end(Phases.stream_sink(config, stdout), report)
  end

  defp maybe_emit_stream_end(_, _, _), do: :ok

  @minimum_elixir "1.18.0"

  defp prepare_pipeline(argv, dispatch, output, mode) do
    otp = dispatch[:otp_release] || otp_version()
    elixir = dispatch[:elixir_version] || System.version()

    case runtime_version_error(otp, elixir) do
      nil ->
        prepare_supported_pipeline(argv, dispatch, output, mode)

      {reason, actual} ->
        {report, config} = abort_report_options(argv, output.root)
        report = update_in(report.meta, &%{&1 | otp_version: otp, elixir_version: elixir})
        {:abort, report, config, reason, %{step: :startup, actual: actual}}
    end
  end

  defp runtime_version_error(otp, elixir) do
    case Integer.parse(otp) do
      {release, ""} when release >= 27 ->
        if Version.compare(elixir, @minimum_elixir) == :lt,
          do: {:unsupported_elixir_version, elixir}

      _ ->
        {:unsupported_otp_version, otp}
    end
  end

  defp prepare_supported_pipeline(argv, dispatch, output, mode) do
    case phase_cli(argv, dispatch) do
      {:ok, config} ->
        report = with_meta(base_report(nil), config)

        case phase_json_path(config, report, output.root) do
          {:ok, config} ->
            with {:ok, config} <- phase_summary_path(config, report, output.root) do
              run_configured_pipeline(mode, config, report, dispatch, output, argv)
            end

          {:abort, _, config, reason, details} ->
            config =
              case phase_summary_path(config, report, output.root) do
                {:ok, config} -> config
                {:abort, _, config, _, _} -> config
              end

            {:abort, report, config, reason, details}
        end

      {:error, reason, details} ->
        {report, config} = abort_report_options(argv, output.root)
        {:abort, report, config, reason, Map.put(details, :step, :cli)}
    end
  end

  defp abort_report_options(argv, root) do
    config = CLI.report_options(argv)
    report = with_meta(base_report(nil), config)

    config =
      case phase_json_path(config, report, root) do
        {:ok, config} -> config
        {:abort, _, config, _, _} -> config
      end

    case phase_summary_path(config, report, root) do
      {:ok, config} -> {report, config}
      {:abort, _, config, _, _} -> {report, config}
    end
  end

  defp run_configured_pipeline({:host, {:error, reason, details}}, config, report, _, _, _) do
    {:abort, report, %{config | stream: false}, reason, details}
  end

  defp run_configured_pipeline(
         mode,
         %Config{since: since} = config,
         report,
         dispatch,
         output,
         argv
       )
       when is_binary(since) or config.tests == ["auto"] or is_binary(config.site) do
    phases = %Phases{config: config, dispatch: dispatch, output: output}
    ChangedRun.run(phases, report, host_command(argv), &with_host(mode, config, &1, argv, &2))
  end

  defp run_configured_pipeline(mode, config, report, dispatch, output, argv) do
    with_host(mode, config, report, argv, fn report, state ->
      phases = %Phases{config: config, dispatch: dispatch, output: output, host: state}
      run_classic(phases, report)
    end)
  end

  defp run_classic(%Phases{config: config, host: state} = phases, report) do
    with {:ok, scopes} <- Phases.scope(phases, report),
         report = %{report | scope: scopes},
         :ok <- check_self_scope(scopes, config, report),
         {:ok, filter} <- Phases.tests(phases, report, state.test_paths),
         filter =
           MutagenEx.TestSelector.merge_helper_filters(
             filter,
             state.exunit,
             Map.get(state, :helper_tags, MapSet.new())
           ),
         report = %{report | tests: Phases.report_tests(filter)},
         {:ok, cache} <- Phases.ast_cache(phases, scopes, filter, report),
         {:ok, coverage, report} <- Phases.coverage(phases, scopes, filter, nil, report),
         report = %{
           report
           | coverage: Phases.report_coverage(coverage),
             stream_end: config.stream
         },
         {:ok, enumeration} <- Phases.enumerate(phases, cache, scopes, coverage, report),
         {:ok, input} <- Phases.test_input(phases, coverage, filter, report),
         {:ok, _baseline, report} <- Phases.baseline(phases, input, report),
         plan = %{cache: cache, scopes: scopes},
         {:ok, outcome, report} <-
           Phases.mutation(phases, plan, input, enumeration.sites, config.budget_ms, report) do
      warnings = report.warnings ++ Phases.enumerator_warnings(enumeration) ++ outcome.warnings

      report = %{
        report
        | mutation: Phases.report_mutation(outcome, enumeration),
          warnings: warnings,
          truncated: Map.get(outcome, :truncated, false) == true
      }

      {:ok, report, config}
    end
  end

  defp with_host(:prepared, _config, report, _argv, pipeline) do
    pipeline.(report, %{test_paths: Runtime.test_paths(), exunit: []})
  end

  defp with_host({:host, :ok}, config, report, argv, pipeline) do
    run_host(config, report, argv, pipeline)
  end

  defp run_host(config, report, argv, pipeline) do
    started_at = System.monotonic_time()

    boot =
      Runtime.boot(
        host_app: config.host_app,
        test_alias: config.test_alias,
        boot_timeout_ms: config.boot_timeout_ms,
        redirect_logger: true,
        defer_cleanup: true,
        command: host_command(argv)
      )

    preloaded = preload_report_modules()
    report = put_timing(report, :boot, started_at)

    case {preloaded, boot} do
      {:ok, {:ok, state}} ->
        install_redact_patterns(state)
        report = add_warnings(report, state.warnings)
        {:cleanup, pipeline.(report, state), state}

      {:ok, {:error, reason, details, state}} ->
        install_redact_patterns(state)
        report = add_warnings(report, state.warnings)
        {:cleanup, {:abort, report, %{config | stream: false}, reason, details}, state}

      {{:error, reason, details}, boot} ->
        abort = {:abort, report, %{config | stream: false}, reason, details}

        case boot do
          {:ok, state} -> {:cleanup, abort, state}
          {:error, _, _, state} -> {:cleanup, abort, state}
          _ -> abort
        end

      {:ok, {:error, reason, details}} ->
        {:abort, report, %{config | stream: false}, reason, details}
    end
  end

  defp install_redact_patterns(state) do
    MutagenEx.JsonReporter.Sanitizer.put_patterns(state.patterns)
  end

  defp add_warnings(report, warnings), do: %{report | warnings: report.warnings ++ warnings}

  defp host_command(argv),
    do: Enum.join(["MIX_ENV=test mix mutagen" | Enum.map(argv, &shell_arg/1)], " ")

  defp shell_arg(arg) do
    if String.match?(arg, ~r/\A[\w\/.:-]+\z/),
      do: arg,
      else: "'" <> String.replace(arg, "'", "'\\''") <> "'"
  end

  defp finish_suite(result, state) do
    report = elem(result, 1)

    stats =
      (report.baseline || report.coverage || %{})[:suite_stats] ||
        Runtime.empty_suite()

    case Runtime.finish(state, stats) do
      :timeout -> IO.puts(:stderr, "warning: after_suite_timeout (#{state.cleanup_timeout} ms)")
      {:error, _, _} -> IO.puts(:stderr, "warning: after_suite_failed")
      :ok -> :ok
    end
  end

  defp check_self_scope(scopes, config, report) do
    case MutationRunner.check_scope(scopes) do
      :ok -> :ok
      {:error, reason, details} -> {:abort, report, config, reason, details}
    end
  end

  defp put_total_timing({:cleanup, result, state}, started_at),
    do: {:cleanup, put_total_timing(result, started_at), state}

  defp put_total_timing(result, started_at) do
    report =
      result
      |> elem(1)
      |> put_timing(:total, started_at)
      |> Phases.put_mutant_deadline(elem(result, 2))

    put_elem(result, 1, report)
  end

  defp put_timing(report, phase, started_at) do
    put_elapsed_timing(report, phase, System.monotonic_time() - started_at)
  end

  defp put_elapsed_timing(%Report{meta: meta} = report, phase, elapsed) do
    elapsed_ms = System.convert_time_unit(elapsed, :native, :millisecond)
    %{report | meta: put_in(meta.timings_ms[phase], elapsed_ms)}
  end

  # ---------------------------------------------------------------------------
  # Phase wrappers
  # ---------------------------------------------------------------------------

  defp phase_cli(argv, dispatch) do
    mod = Map.fetch!(dispatch, :cli)
    mod.parse(argv)
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
  defp phase_json_path(%Config{json_path: nil} = config, _report, _root), do: {:ok, config}

  defp phase_json_path(%Config{json_path: path} = config, report, project_root) do
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

        {:ok,
         %Config{config | json_path: canonical, json_root: project_root, json_requested: path}}

      {:error, reason, details} ->
        {:abort, report, %{config | json_path: nil}, reason,
         Map.put(details, :step, :report_path)}
    end
  end

  defp phase_summary_path(%Config{summary_path: nil} = config, _report, _root), do: {:ok, config}

  defp phase_summary_path(%Config{summary_path: path} = config, report, root) do
    opts = [project_root: root, unsafe_outside_project: config.unsafe_json_outside_project]

    case MutagenEx.JsonPath.canonicalize(path, opts) do
      {:ok, canonical} when canonical != config.json_path ->
        {:ok, %{config | summary_path: canonical, summary_requested: path, json_root: root}}

      {:ok, _same_path} ->
        {:abort, report, config, :summary_path_conflict, %{step: :report_path}}

      {:error, _, _} ->
        {:abort, report, config, :unsafe_summary_path, %{step: :report_path}}
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
        tool_version: Runtime.tool_version(),
        elixir_version: System.version(),
        otp_version: otp_version(),
        exunit_seed: seed || 0,
        timings_ms: %{boot: 0, coverage: 0, baseline: 0, mutation: 0, total: 0}
      },
      scope: [],
      warnings: []
    }
  end

  defp with_meta(%Report{} = r, %Config{} = config) do
    %Report{
      r
      | meta:
          Map.merge(r.meta, %{
            exunit_seed: config.seed,
            fail_fast: config.fail_fast,
            max_concurrency: config.max_concurrency || 1
          }),
        source: config.source,
        include_host_output: config.include_host_output,
        summary_max: config.summary_max,
        rerun_options: summary_rerun_options(config)
    }
  end

  defp summary_rerun_options(config) do
    %{
      seed: config.seed,
      timeout_ms: if(config.timeout_override, do: config.timeout_ms),
      boot_timeout_ms: config.boot_timeout_ms,
      host_app: config.host_app,
      test_alias: config.test_alias,
      fail_fast: config.fail_fast
    }
  end

  defp otp_version do
    :erlang.system_info(:otp_release) |> to_string()
  end

  # ---------------------------------------------------------------------------
  # Emission
  # ---------------------------------------------------------------------------

  defp emit_success(%Report{} = report, %Config{} = config, dispatch) do
    mod = Map.fetch!(dispatch, :reporter_ok)
    {iodata, code} = mod.emit_report(report)

    emit_document(iodata, code, config, dispatch)
    :ok
  end

  defp emit_abort(%Report{} = report, config, reason, details, dispatch) do
    mod = Map.fetch!(dispatch, :reporter_error)

    if Process.get(:mutagen_report_device) && is_binary(details[:message]) do
      IO.puts(:stderr, details.message)
    end

    report = %Report{report | details: details}
    {iodata, code} = mod.emit_error(report, reason)

    emit_document(iodata, code, config, dispatch)

    {:aborted, reason, %Report{report | aborted: true, abort_reason: Atom.to_string(reason)}}
  end

  defp emit_document(iodata, code, config, %{cleanup: cleanup}) do
    MutagenEx.Pipeline.DefaultIo.emit(iodata, code, config, cleanup)
  end

  defp emit_document(iodata, code, config, %{io: io_mod}), do: io_mod.emit(iodata, code, config)

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
