defmodule MutagenEx.CiWorkflowTest do
  use ExUnit.Case, async: true

  @tag spec: "mutagen.cli.r29"
  test "jobs pin actions and the toolchain without persisting credentials" do
    workflow = File.read!(".github/workflows/ci.yml")
    actions = Regex.scan(~r/^\s*uses:\s*([^\n]+)$/m, workflow, capture: :all_but_first)

    assert length(actions) == 6
    assert Enum.all?(actions, fn [action] -> action =~ ~r/@[0-9a-f]{40} # v\d+$/ end)
    assert length(Regex.scan(~r/persist-credentials: false/, workflow)) == 2
    assert length(Regex.scan(~r/version-file: \.tool-versions/, workflow)) == 2
    assert length(Regex.scan(~r/version-type: strict/, workflow)) == 2
  end
end
