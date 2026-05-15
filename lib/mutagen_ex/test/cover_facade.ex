defmodule MutagenEx.Test.CoverFacade do
  @moduledoc """
  Behaviour for the OTP `:cover` test seam used by
  `MutagenEx.CoverageRunner`.

  Production code talks to the `:cover` Erlang module (lifted from
  `lib/tools-*/ebin` on first use); the facade exists so tests can swap
  a fake recording stub and assert on the lifecycle (start, compile,
  analyse, stop) without touching the real cover_server.

  ## Default

  `MutagenEx.Test.Cover` delegates to `:cover`.
  """

  @typedoc "Result of `:cover.start/0`."
  @type start_result :: {:ok, pid()} | {:error, {:already_started, pid()}} | term()

  @typedoc "Result of `:cover.compile_beam/1`."
  @type compile_beam_result :: {:ok, module()} | {:error, term()}

  @typedoc "Result of `:cover.analyse/3` with `:coverage` + `:line`."
  @type analyse_result ::
          {:ok, [{{module(), pos_integer()}, {non_neg_integer(), non_neg_integer()}}]}
          | {:error, term()}

  @doc "Start the cover_server. Mirrors `:cover.start/0`."
  @callback start() :: start_result()

  @doc "Stop the cover_server. Mirrors `:cover.stop/0`."
  @callback stop() :: any()

  @doc """
  Instrument a `.beam` for coverage. Mirrors `:cover.compile_beam/1`.

  `path` is the charlist returned by `:code.which/1`; the runner does
  the conversion at the call site.
  """
  @callback compile_beam(path :: charlist()) :: compile_beam_result()

  @doc """
  Analyse coverage for an instrumented module. Mirrors
  `:cover.analyse(module, :coverage, :line)`.
  """
  @callback analyse(module :: module(), type :: atom(), granularity :: atom()) ::
              analyse_result()
end
