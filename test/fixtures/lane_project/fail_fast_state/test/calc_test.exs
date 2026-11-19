defmodule FailFastState.ATest do
  use ExUnit.Case

  test "flag starts unset, then this test sets it" do
    refute Application.get_env(:fail_fast_state, :flag), "flag leaked from an earlier run"
    Application.put_env(:fail_fast_state, :flag, true)
    _ = FailFastState.Calc.size(5)
  end

  test "add" do
    assert FailFastState.Calc.add(1, 2) == 3
  end
end

defmodule FailFastState.ZTest do
  use ExUnit.Case

  test "cleanup resets the flag" do
    Application.delete_env(:fail_fast_state, :flag)
  end
end
