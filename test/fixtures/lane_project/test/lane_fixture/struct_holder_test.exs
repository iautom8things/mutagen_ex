defmodule LaneFixture.StructHolderTest do
  @moduledoc """
  Tight + toothless tests for `LaneFixture.StructHolder`.

  Exercises the struct-defining module via its public builder and
  predicate. The tight test pins `empty?/1`'s comparison so the literal
  flip `0 → 1` is killed; the toothless test only checks struct shape.
  """

  use ExUnit.Case, async: false

  test "new/1 creates a struct with count 0 (tight: kills literal flip)" do
    s = LaneFixture.StructHolder.new("alpha")
    assert s.count == 0
    assert s.name == "alpha"
  end

  test "empty?/1 is true on fresh struct (tight)" do
    s = LaneFixture.StructHolder.new("beta")
    assert LaneFixture.StructHolder.empty?(s) == true
  end

  test "empty?/1 is false when count is nonzero (tight: kills `==` swap)" do
    s = %LaneFixture.StructHolder{name: "gamma", count: 5}
    assert LaneFixture.StructHolder.empty?(s) == false
  end

  test "new/1 returns a struct (toothless)" do
    assert %LaneFixture.StructHolder{} = LaneFixture.StructHolder.new("delta")
  end
end
