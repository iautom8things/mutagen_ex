defmodule Mix.Tasks.Mutagen do
  @shortdoc "Run mutation testing against a scope, gated by cited tests"

  @moduledoc """
  # mix mutagen

  ## Synopsis

      mix mutagen --scope <target> --tests <target> [--timeout-ms N] [--seed N] [--json PATH]

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
      of stdout. The document always ends with a single newline.

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
  """

  use Mix.Task

  alias MutagenEx.CLI

  @typedoc """
  Pluggable collaborators for the mix task's state machine. Each entry is a
  `{module, function}` pair the task uses instead of a hard-coded call, so
  the error paths (and, in later stages, the happy path) can be unit-tested
  by injecting fakes that capture their arguments.

  Per the ticket: "Mix task skeleton with a private dispatch table so the
  state machine error paths can be unit-tested by injecting fake
  collaborators." The pipeline collaborator is a placeholder — its real
  implementation lands in S6 (mutation_pipeline).
  """
  @type dispatch :: %{
          required(:reporter) => {module(), atom()},
          required(:pipeline) => {module(), atom()}
        }

  @impl Mix.Task
  def run(argv) do
    run(argv, default_dispatch())
  end

  @doc """
  Test seam: run the task with a custom dispatch table.

  Production code calls `run/1`, which threads through `default_dispatch/0`.
  Tests call `run/2` with stub collaborators that capture invocations
  instead of running the real pipeline or printing JSON.

  The return value mirrors what `run/1` does observably:
    * `:ok` on a successful parse+dispatch
    * `{:error, reason, details}` on a parse failure (the reporter
      collaborator was still called with these values before return)

  `run/1` itself does not return one of these — it calls `System.halt/1` via
  the default reporter on error. `run/2` lets tests observe without halting
  the test VM.
  """
  @spec run([String.t()], dispatch()) ::
          :ok | {:error, CLI.reason(), map()}
  def run(argv, dispatch) when is_list(argv) and is_map(dispatch) do
    case CLI.parse(argv) do
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

  # --- defaults ---------------------------------------------------------------

  @doc false
  # Exposed only for `run/1` — tests should pass their own dispatch via
  # `run/2` rather than depending on this default.
  @spec default_dispatch() :: dispatch()
  def default_dispatch do
    %{
      reporter: {__MODULE__, :default_report_error},
      pipeline: {__MODULE__, :default_run_pipeline}
    }
  end

  @doc false
  # Default error reporter for production use. Emits a placeholder text
  # representation to stderr and halts non-zero. The real JSON shape is
  # owned by `MutagenEx.JsonReporter` (S5); until that ships, the placeholder
  # here is a clearly-marked stand-in so an early-stage user gets *some*
  # feedback rather than a silent crash.
  @spec default_report_error(CLI.reason(), map()) :: no_return()
  def default_report_error(reason, details) do
    message = Map.get(details, :message, "mutagen: error")
    Mix.shell().error("mutagen: error (#{reason}) — #{message}")
    Mix.shell().error("(error-JSON emission lands with MutagenEx.JsonReporter in S5)")
    System.halt(2)
  end

  @doc false
  # Default pipeline entry. The real implementation lands in S6
  # (mutation_pipeline); for now it raises a clearly-named error so a user
  # who runs `mix mutagen` in this early stage gets a useful signal rather
  # than mysterious behaviour.
  @spec default_run_pipeline(MutagenEx.Config.t()) :: no_return()
  def default_run_pipeline(_config) do
    raise "MutagenEx.MutationPipeline.run/1 is not yet implemented (lands in S6)"
  end
end
