defmodule LaneFixture.Withblock do
  @moduledoc """
  `with`-block fixture for the lane project.

  Exercises the `:with_swap` mutator (catalog entry 5) and the
  `:else_removal` mutator (catalog entry 9). The `safe_lookup/2` function
  has two leading `<-` clauses and an `else` branch — both shapes the
  catalog matches.

  The tight tests assert specific results that change when either
  mutation lands; the toothless test only checks return shape and lets
  the unhardened mutation survive.
  """

  def safe_lookup(map, key) do
    with {:ok, value} <- Map.fetch(map, key),
         true <- is_integer(value) do
      {:ok, value * 2}
    else
      :error -> {:error, :missing}
      _ -> {:error, :not_integer}
    end
  end
end
