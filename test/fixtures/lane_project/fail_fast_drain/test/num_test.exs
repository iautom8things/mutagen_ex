defmodule FailFastDrain.NumTest do
  use ExUnit.Case

  test "arith" do
    assert FailFastDrain.Num.add(2, 3) == 5
    assert FailFastDrain.Num.sub(5, 3) == 2
    assert FailFastDrain.Num.mul(2, 3) == 6
  end
end
