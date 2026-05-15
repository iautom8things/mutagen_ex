defmodule MutagenEx.Test.Cover do
  @moduledoc """
  Default `MutagenEx.Test.CoverFacade` implementation — thin wrapper
  over Erlang's `:cover` module.

  `:cover` lives under OTP's `tools-*/ebin` and is loaded on demand by
  `MutagenEx.CoverageRunner.ensure_cover_loadable/1`. The wrapper
  functions in this module assume that ensure step has already run; they
  do not re-attempt the path-append themselves.

  Tests swap a different module via the `:cover` config key.
  """

  @behaviour MutagenEx.Test.CoverFacade

  # `:cover` is not on the default Mix code path until
  # `MutagenEx.CoverageRunner.ensure_cover_loadable/1` appends
  # `lib/tools-*/ebin`. We use `apply/3` here to defer the resolution
  # past compile-time so `mix compile --warnings-as-errors` does not
  # flag `:cover.*/N is undefined`. By the time these functions are
  # called, the runner has already ensured `:cover` is loaded.

  @impl MutagenEx.Test.CoverFacade
  def start, do: apply(:cover, :start, [])

  @impl MutagenEx.Test.CoverFacade
  def stop, do: apply(:cover, :stop, [])

  @impl MutagenEx.Test.CoverFacade
  def compile_beam(path), do: apply(:cover, :compile_beam, [path])

  @impl MutagenEx.Test.CoverFacade
  def analyse(module, type, granularity),
    do: apply(:cover, :analyse, [module, type, granularity])
end
