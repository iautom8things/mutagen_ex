defmodule LaneFixture.GuardedTest do
  @moduledoc """
  Happy-path and guard rejection tests for `LaneFixture.Guarded`.

  The tight tests confirm the guard's behaviour by feeding values that
  the guard's domain rejects, expecting a `FunctionClauseError`. If the
  `:guard_drop` mutator removes the `when` clause, those arguments now
  match successfully — the assertion of `assert_raise` fails, killing
  the mutation.

  The happy-path tests confirm the accepted values. The rejection tests
  kill the guard removal mutants.
  """

  use ExUnit.Case, async: false

  test "only_positive/1 raises on 0 (tight: kills guard_drop)" do
    assert_raise FunctionClauseError, fn ->
      LaneFixture.Guarded.only_positive(0)
    end
  end

  test "only_positive/1 raises on negative (tight: kills guard_drop)" do
    assert_raise FunctionClauseError, fn ->
      LaneFixture.Guarded.only_positive(-5)
    end
  end

  test "only_atoms/1 raises on integer (tight: kills guard_drop)" do
    assert_raise FunctionClauseError, fn ->
      LaneFixture.Guarded.only_atoms(123)
    end
  end

  test "only_positive/1 returns the positive value (tight happy path)" do
    assert LaneFixture.Guarded.only_positive(5) == 5
  end

  test "only_atoms/1 returns the atom" do
    assert LaneFixture.Guarded.only_atoms(:foo) == :foo
  end
end
