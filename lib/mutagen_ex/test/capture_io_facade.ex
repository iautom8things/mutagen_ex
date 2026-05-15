defmodule MutagenEx.Test.CaptureIoFacade do
  @moduledoc """
  Behaviour for the `ExUnit.CaptureIO` test seam used by
  `MutagenEx.MutationRunner` (around the swap-compile call) and
  `MutagenEx.MutationRunner.MutationLoop` (around the per-site test
  run, to absorb compiler warnings and any other stderr emitted during
  the mutation cycle).

  Production code uses `ExUnit.CaptureIO.with_io/3`'s 2-arity form via
  this facade so call sites can compile-time-dispatch against a
  behaviour rather than `apply/3` an arbitrary module reference.

  ## Default

  `MutagenEx.Test.CaptureIo` delegates to `ExUnit.CaptureIO`.
  """

  @typedoc "Device atom or pid accepted by ExUnit.CaptureIO.with_io/2."
  @type device :: atom() | pid()

  @doc """
  Run `fun` while capturing IO written to `device`. Mirrors
  `ExUnit.CaptureIO.with_io/2`.

  Returns `{closure_result, captured_io_binary}`.
  """
  @callback with_io(device :: device(), fun :: (-> any())) :: {any(), binary()}
end
