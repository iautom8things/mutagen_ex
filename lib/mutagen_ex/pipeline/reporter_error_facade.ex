defmodule MutagenEx.Pipeline.ReporterErrorFacade do
  @moduledoc """
  Behaviour for the `:reporter_error` slot of the `Mix.Tasks.Mutagen`
  dispatch table.

  Production default: `MutagenEx.JsonReporter` (its `emit_error/2`
  is the abort-shape encoder).
  """

  @doc "Encode an abort `%Report{}` + reason into `{iodata, exit_code}`."
  @callback emit_error(
              report :: MutagenEx.JsonReporter.Report.t(),
              abort_reason :: atom()
            ) :: {iodata(), non_neg_integer()}
end
