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
  defdelegate run(), to: ExUnit

  @doc false
  def options(seed, filter, max_failures) do
    [
      max_cases: 1,
      max_failures: max_failures,
      seed: seed,
      formatters: Application.get_env(:ex_unit, :formatters, [ExUnit.CLIFormatter]),
      include: filter.include,
      exclude: filter.exclude
    ]
  end

  @doc false
  def with_options(options, run) do
    # ExUnit.run/0 also persists its effective trace setting.
    previous =
      for key <- [:trace | Keyword.keys(options)] do
        {key, Application.fetch_env(:ex_unit, key)}
      end

    try do
      put_options(options)
      run.()
    after
      put_options(for {key, {:ok, value}} <- previous, do: {key, value})

      for {key, :error} <- previous, do: Application.delete_env(:ex_unit, key)
    end
  end

  defp put_options(options) do
    Enum.each(options, fn {key, value} -> Application.put_env(:ex_unit, key, value) end)
  end
end
