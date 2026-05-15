defmodule MutagenEx.Pipeline.EnumeratorFacade do
  @moduledoc """
  Behaviour for the `:enumerator` slot of the `Mix.Tasks.Mutagen`
  dispatch table.

  Production default: `MutagenEx.MutationEnumerator`. The Mix task
  calls `mod.enumerate(ast_cache, scope_records, covered_lines, opts)`
  with the accumulated scope + coverage state.
  """

  @doc """
  Enumerate mutation sites against `ast_cache` filtered by
  `covered_lines`. Returns either an enumeration map (`%{sites,
  skipped, warnings}`) or `{:error, :too_many_sites, details}` when
  the cap from `opts[:max_sites]` is exceeded.
  """
  @callback enumerate(
              ast_cache :: map(),
              scope_records :: [map()],
              covered_lines :: map(),
              opts :: keyword()
            ) ::
              %{sites: list(), skipped: list(), warnings: list()}
              | {:error, :too_many_sites, map()}
end
