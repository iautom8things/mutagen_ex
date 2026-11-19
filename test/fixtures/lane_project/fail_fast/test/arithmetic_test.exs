defmodule FailFastFixture.EarlyTest do
  use ExUnit.Case, async: true

  alias FailFastFixture.Arithmetic
  alias MutagenEx.FailFastTest.Probe

  test "exact arithmetic", %{async: async} do
    scenario = Probe.record_test(:first)
    if scenario == :red, do: flunk("first baseline failure")

    if scenario == :before_failure do
      Probe.record({:async, async})
      if Arithmetic.first(2, 3) != 5, do: Process.sleep(800)
    end

    if scenario == :budget and Arithmetic.first(2, 3) != 5, do: Process.sleep(50)
    assert_original_arithmetic()
  end

  test "checks arithmetic again" do
    scenario = Probe.record_test(:same_module_tail)
    if scenario == :red, do: flunk("second baseline failure")
    assert_original_arithmetic()
  end

  defp assert_original_arithmetic do
    assert Arithmetic.first(2, 3) == 5
    assert Arithmetic.second(4, 3) == 1
    assert Arithmetic.third(2, 3) == 6
  end
end

defmodule FailFastFixture.TailTest do
  use ExUnit.Case

  alias FailFastFixture.Arithmetic
  alias MutagenEx.FailFastTest.Probe

  test "slow trailing test" do
    scenario = Probe.record_test(:next_module_tail)
    assert is_number(Arithmetic.loose(2, 3))

    if scenario == :after_failure and Arithmetic.first(2, 3) != 5 do
      Process.sleep(800)
    end

    if scenario == :benchmark do
      Process.sleep(100)
    end
  end
end
