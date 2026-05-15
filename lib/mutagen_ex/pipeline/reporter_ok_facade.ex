defmodule MutagenEx.Pipeline.ReporterOkFacade do
  @moduledoc """
  Behaviour for the `:reporter_ok` slot of the `Mix.Tasks.Mutagen`
  dispatch table.

  Production default: `MutagenEx.JsonReporter` (its `emit_report/1`
  is the success-shape encoder).
  """

  @doc "Encode a success `%Report{}` into `{iodata, exit_code}`."
  @callback emit_report(report :: MutagenEx.JsonReporter.Report.t()) ::
              {iodata(), non_neg_integer()}
end
