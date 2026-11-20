defmodule MutagenEx.CiWorkflowTest do
  use ExUnit.Case, async: true

  @tag spec: "mutagen.cli.r29"
  test "jobs pin actions and the toolchain without persisting credentials" do
    workflow = File.read!(".github/workflows/ci.yml")
    actions = Regex.scan(~r/^\s*uses:\s*([^\n]+)$/m, workflow, capture: :all_but_first)

    assert length(actions) == 8
    assert Enum.all?(actions, fn [action] -> action =~ ~r/@[0-9a-f]{40} # v\d+\.\d+\.\d+$/ end)
    assert length(Regex.scan(~r/persist-credentials: false/, workflow)) == 3
    assert length(Regex.scan(~r/version-file: \.tool-versions/, workflow)) == 3
    assert length(Regex.scan(~r/version-type: strict/, workflow)) == 3

    assert workflow =~
             "mix test test/mutagen_ex/end_to_end_test.exs test/mutagen_ex/determinism_test.exs --only e2e_slow"

    assert workflow =~ ~r/^  build:\n(?:[^\n]+\n)*?    timeout-minutes: 10$/m
  end
end
