defmodule MutagenEx.BaselineRedGuardFixtures.RedCitedTest do
  @moduledoc """
  Deliberately-failing cited test module for
  `MutagenEx.BaselineRedGuardTest` (mutagen-hcs.4).

  Lives under `test/fixtures/` so the parent project's `mix test` loader
  ignores it (see `mix.exs` `test_ignore_filters`). The guard test
  `Code.require_file/1`s it explicitly, fires the `use ExUnit.Case`
  registration once, drains it with a nested `ExUnit.run/0`, then asserts
  the production baseline still detects the red cited test via
  `ExUnit.Server.add_module/2` re-registration.
  """

  use ExUnit.Case, async: false

  # Excluded from the parent suite via `test/test_helper.exs` so the
  # deliberately-red test below is never reported as a top-level failure.
  # `MutagenEx.BaselineRedGuardTest` re-includes the tag in its own nested
  # `ExUnit.run/0` invocations to drive this module on purpose.
  @moduletag :mutagen_baseline_red_guard

  test "deliberately red baseline trigger" do
    assert 1 == 2
  end
end
