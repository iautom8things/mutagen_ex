defmodule LaneFixture.WithblockTest do
  @moduledoc """
  Tight + toothless tests for `LaneFixture.Withblock`.

  The tight tests pin both the happy path and the two distinct error
  paths so that either:

    * `:with_swap` (swapping the `Map.fetch` clause with the `is_integer`
      clause) — after the swap, `is_integer(value)` references a
      variable bound by the now-second clause, which the catalog's
      validator should mark `:bound_var_used_before_binding` and skip
      OR which fails at runtime with an `UndefinedFunctionError`.
    * `:else_removal` — without the `else` block, the `with` returns
      the failing clause's value directly (`:error` or `false`), not
      the wrapped `{:error, _}` tuple. The error-path asserts pin the
      tagged tuple, so the swap kills.

  The toothless test only checks the happy path's return shape (a
  tuple); both mutations may survive against it.
  """

  use ExUnit.Case, async: false

  test "safe_lookup/2 happy path doubles the value (tight)" do
    assert LaneFixture.Withblock.safe_lookup(%{a: 3}, :a) == {:ok, 6}
  end

  test "safe_lookup/2 missing key returns {:error, :missing} (tight: kills else_removal)" do
    assert LaneFixture.Withblock.safe_lookup(%{a: 3}, :nope) == {:error, :missing}
  end

  test "safe_lookup/2 non-integer value returns {:error, :not_integer} (tight: kills else_removal)" do
    assert LaneFixture.Withblock.safe_lookup(%{a: "three"}, :a) == {:error, :not_integer}
  end

  test "safe_lookup/2 returns a 2-tuple (toothless: with_swap may survive)" do
    result = LaneFixture.Withblock.safe_lookup(%{a: 1}, :a)
    assert is_tuple(result) and tuple_size(result) == 2
  end
end
