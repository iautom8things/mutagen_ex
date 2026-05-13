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

  Per `mutagen.cli.r3`, `timeout_ms` defaults to 5000.
  Per `mutagen.cli.r4`, `seed` defaults to 0.
  Per `mutagen.cli.r5`, `json_path` is `nil` when output should go to stdout.
  """

  alias MutagenEx.Types

  @enforce_keys [:scopes, :tests]
  defstruct scopes: [],
            tests: [],
            timeout_ms: 5_000,
            seed: 0,
            json_path: nil

  @type t :: %__MODULE__{
          scopes: [Types.scope_target()],
          tests: [Types.test_target()],
          timeout_ms: pos_integer(),
          seed: non_neg_integer(),
          json_path: Path.t() | nil
        }
end
