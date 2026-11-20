defmodule ChangedRunFixture.BranchCoverageTest do
  use ExUnit.Case

  test "live shapes" do
    assert ChangedRunFixture.Example.guard_live(20) == 40
    assert ChangedRunFixture.Example.guard_live(1) == 1
    assert ChangedRunFixture.Example.guard_cold(1) == 1
    assert ChangedRunFixture.Example.multi_live([1, 2]) == 3
    assert ChangedRunFixture.Example.pipe([1, 2], true) == 5
    assert ChangedRunFixture.Example.tup(:a, 1) == {:ok, 2}
    assert ChangedRunFixture.Example.one_live(1) == 2
    assert ChangedRunFixture.Example.two(0) == :zero
    assert ChangedRunFixture.Example.partial(1) == 2
    assert ChangedRunFixture.Example.arm(:a) == 1
    assert ChangedRunFixture.Example.branch_tuple(1, true) == {:ok, 1}
    assert ChangedRunFixture.Example.branch_tuple_lit(true) == {:ok, true}
    assert ChangedRunFixture.Example.branch_tuple_multi(1, true) == {:ok, 1}
    assert ChangedRunFixture.Example.arm_tuple(:a) == {:ok, 1}
    assert ChangedRunFixture.Example.cond_tuple(1) == {:ok, 1}
    assert ChangedRunFixture.Example.with_else({:ok, 2}) == 2
    assert ChangedRunFixture.Example.with_else_taken(:missing) == {:error, false}
    assert ChangedRunFixture.Example.nested_branch(-1, true, true) == {:ok, 1}
    assert ChangedRunFixture.Example.unless_pipe([1], true) == nil
  end
end
