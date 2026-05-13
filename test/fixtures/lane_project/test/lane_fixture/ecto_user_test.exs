defmodule LaneFixture.EctoUserTest do
  @moduledoc """
  Tight + toothless tests for `LaneFixture.EctoUser`.

  This is the C1-analogue: the test asserts that the macro-injected
  callbacks (`__schema_kind__/0`, the persisted attribute, the
  `field/2`-generated functions) survive every restore cycle. The end-
  to-end test pairs this with a bytecode MD5 check before/after a full
  mutation pass.
  """

  use ExUnit.Case, async: false

  test "EctoUser exposes the macro-injected schema kind (tight)" do
    assert LaneFixture.EctoUser.__schema_kind__() == :registered
  end

  test "field/2 generated name/0 returns its type (tight)" do
    assert LaneFixture.EctoUser.name() == :string
  end

  test "field/2 generated age/0 returns its type (tight)" do
    assert LaneFixture.EctoUser.age() == :integer
  end

  test "birthday/1 increments age (tight: kills `+` swap)" do
    assert LaneFixture.EctoUser.birthday(30) == 31
  end

  test "persisted attribute survives compile (tight)" do
    attrs = LaneFixture.EctoUser.__info__(:attributes)
    assert Keyword.has_key?(attrs, :lane_schema_kind)
    assert :registered in Keyword.get_values(attrs, :lane_schema_kind)
  end

  test "birthday/1 returns an integer (toothless)" do
    assert is_integer(LaneFixture.EctoUser.birthday(0))
  end
end
