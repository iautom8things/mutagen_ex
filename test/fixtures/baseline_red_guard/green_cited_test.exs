defmodule MutagenEx.BaselineRedGuardFixtures.GreenCitedTest do
  @moduledoc """
  Passing cited test module for `MutagenEx.BaselineRedGuardTest`
  (mutagen-hcs.4). The green control: re-registration must not
  manufacture failures. See the red sibling in this directory.
  """

  use ExUnit.Case, async: false

  # Excluded from the parent suite via `test/test_helper.exs`; the guard
  # test drives it through nested `ExUnit.run/0` calls that re-include the
  # tag. (Kept off the default run for symmetry with the red sibling, even
  # though this one passes.)
  @moduletag :mutagen_baseline_red_guard

  test "passing cited test" do
    assert 1 == 1
  end
end
