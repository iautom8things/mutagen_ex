defmodule MutagenEx.Test.FailureFormatterTest do
  use ExUnit.Case, async: true

  alias MutagenEx.Test.FailureFormatter

  @tag spec: "mutagen.mutation_pipeline.r1"
  test "records failed, invalid and teardown-invalidated tests once" do
    caller = self()
    record = fn runner, test -> send(caller, {:recorded, runner, test.name}) end
    options = FailureFormatter.attach([formatters: [ExUnit.CLIFormatter], seed: 0], record)

    assert options[:formatters] == [ExUnit.CLIFormatter, FailureFormatter]
    assert options[:mutagen_on_failure] == record

    state = {:runner, record}
    failed = %ExUnit.Test{name: :"test failed", module: Sample, state: {:failed, []}}
    invalid = %ExUnit.Test{name: :"test invalid", module: Sample, state: {:invalid, Sample}}
    passed = %ExUnit.Test{name: :"test passed", module: Sample, state: nil}
    skipped = %ExUnit.Test{name: :"test skipped", module: Sample, state: {:skipped, "later"}}

    for test <- [failed, invalid, passed, skipped] do
      assert {:noreply, ^state} = FailureFormatter.handle_cast({:test_finished, test}, state)
    end

    torn_down = %ExUnit.TestModule{name: Sample, state: {:failed, []}, tests: [passed, failed]}
    healthy = %ExUnit.TestModule{name: Sample, state: nil, tests: [passed]}

    for module <- [torn_down, healthy] do
      assert {:noreply, ^state} = FailureFormatter.handle_cast({:module_finished, module}, state)
    end

    assert_received {:recorded, :runner, :"test failed"}
    assert_received {:recorded, :runner, :"test invalid"}
    assert_received {:recorded, :runner, :"test passed"}
    refute_received {:recorded, _, _}
  end
end
