defmodule FailFastCleanup.ATest do
  use ExUnit.Case

  test "strict mode rejects zero" do
    if Application.get_env(:fail_fast_cleanup, :strict) do
      assert FailFastCleanup.Calc.check(1)
      refute FailFastCleanup.Calc.check(0)
    end
  end

  test "lenient mode adds" do
    Application.put_env(:fail_fast_cleanup, :strict, false)
    assert FailFastCleanup.Calc.add(1, 2) == 3
  end
end

defmodule FailFastCleanup.ZTest do
  use ExUnit.Case

  test "restores strict mode" do
    Application.put_env(:fail_fast_cleanup, :strict, true)
  end
end
