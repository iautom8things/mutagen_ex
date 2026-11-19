defmodule MutagenEx.AutoTestsTest do
  use ExUnit.Case, async: false

  alias MutagenEx.AutoTests

  @tag :tmp_dir
  @tag spec: ["mutagen.test_selection.r9", "mutagen.test_selection.r10"]
  test "uses configured roots and ranks whole module names and calls before applying the cap", %{
    tmp_dir: dir
  } do
    File.cd!(dir, fn ->
      File.mkdir_p!("checks/nested")
      File.write!("checks/nested/example_test.exs", "# convention")
      File.write!("checks/module_test.exs", "alias Fixture.Parent\nExample.call(1)")

      File.write!(
        "checks/full_test.exs",
        "Fixture.Parent.Example.call(1)\nFixture.Parent.Example.call(2)"
      )

      File.write!("checks/function_test.exs", "# Example\n&call/1")
      File.write!("checks/decoy_test.exs", "# Fixture.Parent.ExampleOther callable(1)")
      File.write!("checks/other_test.exs", "# Another.Fixture.Parent.Example")
      File.ln_s!("full_test.exs", "checks/symlink_test.exs")

      assert [
               %{path: "checks/function_test.exs", why: :changed_in_diff},
               %{path: "checks/nested/example_test.exs", why: :convention}
             ] =
               AutoTests.select(
                 [%{file: "src/nested/example.ex"}, %{file: "src/nested/unmatched.ex"}],
                 ["src"],
                 ["checks"],
                 ["checks/function_test.exs"]
               )

      survivors = [%{function: "Fixture.Parent.Example.call/1"}]

      assert {["checks/full_test.exs"], true} =
               AutoTests.discover(:module, survivors, ["checks"], MapSet.new(), 1)

      tried = MapSet.new(["checks/full_test.exs"])

      assert {["checks/module_test.exs"], false} =
               AutoTests.discover(:module, survivors, ["checks"], tried, 20)

      tried = MapSet.put(tried, "checks/module_test.exs")

      assert {["checks/function_test.exs"], false} =
               AutoTests.discover(:function, survivors, ["checks"], tried, 20)
    end)
  end
end
