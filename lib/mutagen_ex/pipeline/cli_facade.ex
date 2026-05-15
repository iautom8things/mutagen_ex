defmodule MutagenEx.Pipeline.CliFacade do
  @moduledoc """
  Behaviour for the `:cli` slot of the `Mix.Tasks.Mutagen` dispatch table.

  Production default: `MutagenEx.CLI` (declared `@behaviour
  MutagenEx.Pipeline.CliFacade`). Tests swap a stub module that emits
  captured argv / canned `{:error, reason, details}` shapes.

  The behaviour exists so the Mix task can dispatch via a plain module
  atom (`mod.parse(argv)`) rather than `apply/3` against a `{mod, fun}`
  tuple — see bw mutagen-wrd.33.
  """

  @doc "Parse argv into a `%MutagenEx.Config{}` or a structured error."
  @callback parse(argv :: [String.t()]) ::
              {:ok, MutagenEx.Config.t()}
              | {:error, MutagenEx.CLI.reason(), map()}
end
