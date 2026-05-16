defmodule MutagenEx.Test.CodeServerFacade do
  @moduledoc """
  Behaviour for the `:code` module seam used by `MutagenEx.BeamCache`.

  Per [`mutagen.decision.code_server_facade`](../../../.spec/decisions/code_server_facade.md),
  `MutagenEx.MutationRunner`'s restore path now performs a binary swap via
  `:code.load_binary/3` from a snapshot taken via `:code.get_object_code/1`.
  Both functions mutate global BEAM state (the loaded-module table and the
  on-disk path resolution), so direct tests would either need to tolerate
  state leakage between cases or restore by hand after every assertion.

  The facade isolates those two calls behind a behaviour. Production code
  uses `MutagenEx.Test.CodeServer`, which delegates straight to the `:code`
  module. Tests inject a stub that records calls and returns canned
  responses without touching the live module table.

  ## Pattern parity

  This facade mirrors `MutagenEx.Test.CompilerFacade` exactly:

    * One module per real-OTP boundary.
    * `cfg.code_server` selects the implementation (defaults to
      `MutagenEx.Test.CodeServer`), the same shape as `cfg.compiler`.
    * Test stubs declare `@behaviour MutagenEx.Test.CodeServerFacade` to
      get compile-time wiring checks.
  """

  @typedoc "Result of `:code.get_object_code/1`."
  @type get_object_code_result ::
          {module(), binary(), charlist()}
          | :error

  @typedoc "Result of `:code.load_binary/3`."
  @type load_binary_result ::
          {:module, module()}
          | {:error, term()}

  @doc """
  Read the currently-loaded `.beam` for `module`. Mirrors
  `:code.get_object_code/1`.

  Returns `{module, binary, filename}` for a loaded module, or `:error`
  when the code server cannot resolve the module (not loaded, no `.beam`
  on disk, etc.).
  """
  @callback get_object_code(module()) :: get_object_code_result()

  @doc """
  Load `binary` as the bytecode for `module`, recording `filename` as
  its on-disk origin. Mirrors `:code.load_binary/3`.

  Used by `MutagenEx.BeamCache.restore/3` to put the snapshot binary
  back after a per-site mutation cycle. Returns `{:module, module}` on
  success.
  """
  @callback load_binary(module(), filename :: charlist(), binary()) :: load_binary_result()
end
