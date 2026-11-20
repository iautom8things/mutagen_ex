defmodule MutagenEx.AutoTestsTest do
  use ExUnit.Case, async: false

  alias MutagenEx.{AutoTests, FileIdentity}

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

      File.write!("checks/function_test.exs", "# Example\n&Example.call/1")
      File.write!("checks/decoy_test.exs", "# Fixture.Parent.ExampleOther callable(1)")
      File.write!("checks/other_test.exs", "# Another.Fixture.Parent.Example")
      File.ln_s!("full_test.exs", "checks/symlink_test.exs")

      assert [
               %{path: "checks/decoy_test.exs", why: :changed_in_diff},
               %{path: "checks/function_test.exs", why: :changed_in_diff},
               %{path: "checks/module_test.exs", why: :changed_in_diff},
               %{path: "checks/nested/example_test.exs", why: :convention},
               %{path: "checks/other_test.exs", why: :changed_in_diff}
             ] =
               AutoTests.select(
                 [%{file: "src/nested/example.ex", module: Fixture.Parent.Example}],
                 ["src"],
                 ["checks"],
                 [
                   "checks/function_test.exs",
                   "checks/module_test.exs",
                   "checks/decoy_test.exs",
                   "checks/other_test.exs"
                 ]
               )

      survivors = [%{function: "Fixture.Parent.Example.call/1"}]

      assert {["checks/full_test.exs"], true, []} =
               AutoTests.discover(:module, survivors, ["checks"], MapSet.new(), 1)

      tried = MapSet.new(["checks/full_test.exs"])

      assert {["checks/module_test.exs"], false, []} =
               AutoTests.discover(:module, survivors, ["checks"], tried, 1)

      tried = MapSet.put(tried, "checks/module_test.exs")

      assert {["checks/function_test.exs"], false, []} =
               AutoTests.discover(:function, survivors, ["checks"], tried, 1)
    end)
  end

  @tag :tmp_dir
  @tag spec: "mutagen.test_selection.r11"
  test "ranks brace aliases and references to an explicit alias in the module pass", %{
    tmp_dir: dir
  } do
    File.cd!(dir, fn ->
      File.mkdir_p!("checks")
      File.write!("checks/brace_test.exs", "alias Shop.Data.{Other, Store}\nStore.get(x)")
      File.write!("checks/named_test.exs", "alias Shop.Data.Store, as: S\nS.get(x)\n&S.get/1")
      File.write!("checks/full_test.exs", "Shop.Data.Store.get(x)")
      File.write!("checks/decoy_test.exs", "alias Shop.Data.{Other, Storefront}\nStore.get(x)")
      sites = [%{function: "Shop.Data.Store.get/1"}]

      assert {["checks/named_test.exs", "checks/brace_test.exs", "checks/full_test.exs"], false,
              []} =
               AutoTests.discover(:module, sites, ["checks"], MapSet.new(), 5)
    end)
  end

  @tag :tmp_dir
  @tag spec: "mutagen.test_selection.r9"
  test "selects a changed path once when the conventional path names the same file", %{
    tmp_dir: dir
  } do
    File.cd!(dir, fn ->
      File.mkdir_p!("checks")
      changed = "checks/renamed_test.exs"
      convention = "checks/example_test.exs"
      File.write!(changed, "# one test file")
      File.ln!(changed, convention)

      assert FileIdentity.same?(changed, convention)
      refute FileIdentity.same?(changed, "checks/missing_test.exs")

      assert [%{path: ^changed, why: :changed_in_diff}] =
               AutoTests.select([%{file: "src/example.ex"}], ["src"], ["checks"], [changed])
    end)
  end

  @tag :tmp_dir
  @tag spec: "mutagen.test_selection.r11"
  test "caps each function, ignores unrelated qualifiers and reports failed reads", %{
    tmp_dir: dir
  } do
    File.cd!(dir, fn ->
      File.mkdir_p!("checks")
      File.write!("checks/noise_test.exs", String.duplicate("# StoreFront Map.get(x, y)\n", 40))
      File.write!("checks/store_test.exs", "&Store.get/2\nStore.get(x, y)")
      File.write!("checks/price_test.exs", "alias Shop.Prices, as: P\nP.price(x)")
      File.write!("checks/read_error_test.exs", "Store.get(x, y)")
      sites = [%{function: "Shop.Store.get/2"}, %{function: "Shop.Prices.price/1"}]

      reader = fn
        "checks/read_error_test.exs" -> {:error, :eacces}
        path -> File.read(path)
      end

      assert {["checks/store_test.exs", "checks/price_test.exs"], false,
              ["checks/read_error_test.exs"]} =
               AutoTests.discover(:function, sites, ["checks"], MapSet.new(), 1, reader)

      File.write!("checks/another_test.exs", "import Shop.Store\nget(x, y)")

      assert {["checks/store_test.exs", "checks/price_test.exs"], true,
              ["checks/read_error_test.exs"]} =
               AutoTests.discover(:function, sites, ["checks"], MapSet.new(), 1, reader)
    end)
  end
end
