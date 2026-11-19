defmodule MutagenEx.Test.ExUnit do
  @moduledoc """
  Default `MutagenEx.Test.ExUnitFacade` implementation — thin wrapper
  over the real `ExUnit` module.

  Production code calls into this module instead of `ExUnit` directly so
  the call sites can be compile-time-dispatched against a behaviour
  (`MutagenEx.Test.ExUnitFacade`) rather than `apply(mod, fun, args)`
  with no Dialyzer leverage.

  Tests swap a different module (implementing the same behaviour) via
  the `:ex_unit` config key.
  """

  @behaviour MutagenEx.Test.ExUnitFacade

  @impl MutagenEx.Test.ExUnitFacade
  defdelegate configure(opts), to: ExUnit

  @impl MutagenEx.Test.ExUnitFacade
  defdelegate run(), to: ExUnit

  @doc false
  def options(seed, filter, max_failures) do
    [
      max_cases: 1,
      max_failures: max_failures,
      seed: seed,
      include: filter.include,
      exclude: filter.exclude
    ]
  end

  @doc false
  def with_options(ex_unit, options, run) do
    # ExUnit.run/0 also persists its effective trace setting.
    previous =
      for key <- [:trace | Keyword.keys(options)] do
        {key, Application.fetch_env(:ex_unit, key)}
      end

    try do
      ex_unit.configure(options)
      run.()
    after
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:ex_unit, key, value)
        {key, :error} -> Application.delete_env(:ex_unit, key)
      end)
    end
  end
end
