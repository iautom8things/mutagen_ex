defmodule MutagenEx.Pipeline.IoFacade do
  @moduledoc """
  Behaviour for the `:io` slot of the `Mix.Tasks.Mutagen` dispatch
  table.

  Production default: `MutagenEx.Pipeline.DefaultIo`, which writes the
  encoded document to stdout or `Config.json_path` and then halts the
  BEAM with `exit_code` (via `System.halt/1`).

  Tests swap a process-message capture so the test VM stays alive
  past the call.
  """

  @doc """
  Sink the final encoded document. The production default halts the
  BEAM; tests pass a non-halting alternative.
  """
  @callback emit(
              iodata :: iodata(),
              exit_code :: non_neg_integer(),
              config :: MutagenEx.Config.t() | nil
            ) :: any()
end
