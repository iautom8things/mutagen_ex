defmodule MutagenEx.Pipeline.TestsFacade do
  @moduledoc """
  Behaviour for the `:tests` slot of the `Mix.Tasks.Mutagen` dispatch
  table.

  Production default: `MutagenEx.TestSelector`. The Mix task calls
  `mod.resolve(tests, opts)` once with the accumulated `--tests`
  targets.
  """

  @doc "Resolve the `--tests` target list into a `%TestFilter{}`."
  @callback resolve(targets :: [String.t()], opts :: keyword()) ::
              {:ok, MutagenEx.TestSelector.TestFilter.t()}
              | {:error, map()}
              | {:error, atom(), map()}
end
