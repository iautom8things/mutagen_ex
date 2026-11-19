ExUnit.configure(
  max_failures: 1,
  seed: 9,
  max_cases: 8,
  formatters: [ExUnit.CLIFormatter],
  include: [:host_only],
  exclude: [:test],
  timeout: 9_999
)

defmodule FailFastHost.RedATest do
  use ExUnit.Case

  setup do
    MutagenEx.FailFastTest.Probe.record({:host_options, Map.new(ExUnit.configuration())})
    :ok
  end

  test "first failure" do
    flunk("one")
  end

  test "second failure" do
    flunk("two")
  end
end
