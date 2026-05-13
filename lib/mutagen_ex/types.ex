defmodule MutagenEx.Types do
  @moduledoc """
  Shared type definitions used across the `mutagen_ex` pipeline.

  This module holds `@type` declarations only — it deliberately defines no
  functions and no struct of its own. The structs themselves live next to the
  modules that own them (e.g. `MutagenEx.Config`); this module gathers the
  cross-cutting shapes the pipeline phases pass between each other so callers
  have one place to look up "what does a `t:mutation_site/0` look like?"

  The concrete modules that *materialise* these types (e.g.
  `MutagenEx.MutationEnumerator` for `t:mutation_site/0`,
  `MutagenEx.JsonReporter` for `t:report/0`) are introduced in later stages.
  The types here are the contract those later modules will satisfy.
  """

  @typedoc "Raw `--scope` target as provided by the user (file, module, or `Module.fun/arity`)."
  @type scope_target :: String.t()

  @typedoc "Raw `--tests` target as provided by the user (file, `file:line`, or `tag:<name>`)."
  @type test_target :: String.t()

  @typedoc "Atom-shaped reason for an error-JSON exit (see `mutagen.json_schema`)."
  @type abort_reason :: atom()

  @typedoc """
  A single mutation site: a specific AST node in a specific file that one
  mutator has rewritten. Materialised by `MutagenEx.MutationEnumerator` in a
  later stage.
  """
  @type mutation_site :: %{
          id: String.t(),
          file: String.t(),
          line: pos_integer(),
          column: pos_integer(),
          mutator: atom(),
          original: String.t(),
          mutated: String.t()
        }

  @typedoc """
  Per-site mutation outcome classification. `:killed` and `:survived` are the
  primary signals; `:timeout` and `:compile_error` are explicit non-classifying
  outcomes per `mutagen.mutation_pipeline`.
  """
  @type mutation_outcome :: :killed | :survived | :timeout | :compile_error

  @typedoc """
  The full report document emitted by `MutagenEx.JsonReporter` in a later
  stage. Successful runs populate every block; aborted runs populate the
  blocks that completed and set `aborted: true` + `abort_reason`.
  """
  @type report :: %{
          version: String.t(),
          meta: map(),
          scope: list(),
          tests: map() | nil,
          baseline: map() | nil,
          coverage: map() | nil,
          mutation: map() | nil,
          warnings: [String.t()],
          aborted: boolean(),
          abort_reason: String.t() | nil
        }
end
