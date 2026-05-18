defmodule MutagenEx.Config do
  @moduledoc """
  Parsed, validated configuration for a single `mix mutagen` invocation.

  This struct is the hand-off from `MutagenEx.CLI.parse/1` to the orchestration
  pipeline. It holds only **raw user input** plus a few flag-level defaults —
  scope target resolution (file paths → modules → MFAs) and test target
  resolution (`tag:` / `file:line` expansion) happen in later stages
  (`mutagen.scope_resolution`, `mutagen.test_selection`).

  Per `mutagen.cli.r1` / `r2`, `scopes` and `tests` accumulate repeated
  `--scope` / `--tests` flags in the order the user supplied them. They are
  stored as the raw strings the user typed; this stage performs no shape
  validation on individual targets (that lives in S3a / S3b — see the
  ticket's Out of Scope (intent) notes).

  Per `mutagen.cli.r3`, `timeout_ms` defaults to 30_000.
  Per `mutagen.cli.r4`, `seed` defaults to 0.
  Per `mutagen.cli.r5`, `json_path` is `nil` when output should go to stdout.
  Per `mutagen.cli.r10`, `unsafe_json_outside_project` defaults to `false`.
  It is set to `true` only when the user explicitly passes
  `--unsafe-json-outside-project`, opting out of the default inside-root
  check on `--json <path>`.

  Per `mutagen.cli.r12`, `max_sites` is the upper bound on enumerated
  mutation sites for one run. Defaults to 10_000. Set via `--max-sites`.

  Per `mutagen.cli.r13`, `budget_ms` is an optional aggregate wall-clock
  budget for the mutation phase in milliseconds. `nil` means unbounded
  (the existing per-site `timeout_ms` is still enforced); set via
  `--budget-ms`.

  Per `mutagen.mutation_pipeline.r15` / `mutagen.json_schema.r10`,
  `max_concurrency` controls the per-site parallelism of the mutation
  loop. The struct default is `nil`; both the Mix task and the runner
  translate `nil` to `1` (fully-serial, v1.0-equivalent). Callers that
  have arranged for collision-free input pass `--max-concurrency N`
  (N > 1) explicitly. `stream` toggles per-site NDJSON emission to
  stdout (default `false`), and `progress` toggles the human-readable
  progress feedback on stderr (default `:auto`, which evaluates "is
  stdout a TTY?" at run time).
  """

  alias MutagenEx.Types

  @enforce_keys [:scopes, :tests]
  defstruct scopes: [],
            tests: [],
            timeout_ms: 30_000,
            seed: 0,
            json_path: nil,
            unsafe_json_outside_project: false,
            max_sites: 10_000,
            budget_ms: nil,
            max_concurrency: nil,
            stream: false,
            progress: :auto

  @type t :: %__MODULE__{
          scopes: [Types.scope_target()],
          tests: [Types.test_target()],
          timeout_ms: pos_integer(),
          seed: non_neg_integer(),
          json_path: Path.t() | nil,
          unsafe_json_outside_project: boolean(),
          max_sites: pos_integer(),
          budget_ms: pos_integer() | nil,
          max_concurrency: pos_integer() | nil,
          stream: boolean(),
          progress: :auto | :on | :off
        }
end
