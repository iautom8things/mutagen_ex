defmodule MutagenEx.Pipeline.ScopeFacade do
  @moduledoc """
  Behaviour for the `:scope` slot of the `Mix.Tasks.Mutagen` dispatch
  table.

  Production default: `MutagenEx.ScopeResolver`. The Mix task calls
  `mod.resolve(target, opts)` once per `--scope` target.
  """

  @doc "Resolve a single `--scope` target to a list of `%Scope{}` records."
  @callback resolve(target :: String.t(), opts :: keyword()) ::
              {:ok, [MutagenEx.ScopeResolver.Scope.t()]}
              | {:error, atom(), map()}
end
