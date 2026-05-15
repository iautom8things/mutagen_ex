defmodule MutagenEx.Test.CaptureIo do
  @moduledoc """
  Default `MutagenEx.Test.CaptureIoFacade` implementation — thin wrapper
  over `ExUnit.CaptureIO`.

  Tests swap a different module via the `:capture_io` config key.
  """

  @behaviour MutagenEx.Test.CaptureIoFacade

  @impl MutagenEx.Test.CaptureIoFacade
  defdelegate with_io(device, fun), to: ExUnit.CaptureIO
end
