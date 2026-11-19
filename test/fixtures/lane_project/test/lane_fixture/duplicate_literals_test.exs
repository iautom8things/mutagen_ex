defmodule LaneFixture.DuplicateLiteralsTest do
  use ExUnit.Case

  alias LaneFixture.DuplicateLiterals

  test "checks the first of each pair and calls every named definition" do
    assert elem(DuplicateLiterals.triple(0), 1) == 1
    assert DuplicateLiterals.opts()[:log] == true
    assert DuplicateLiterals.clause(:first, 1) == 2
    assert DuplicateLiterals.between(1) == 2
    assert DuplicateLiterals.clause(:last, 1) == 2
  end
end
