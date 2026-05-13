defmodule LaneFixture.NoDefsTest do
  @moduledoc """
  Tight test for `LaneFixture.NoDefs`.

  This module is the canary for the `:no_mutation_candidates` warning
  (`mutagen.mutation_enumeration.r5`). It has no mutator-eligible
  sites — only inert module attributes. The test just confirms the
  module compiles and returns its constants; the e2e suite cares about
  the warning surface, not coverage here.
  """

  use ExUnit.Case, async: false

  test "constants/0 returns the inert pair (tight)" do
    assert LaneFixture.NoDefs.constants() == {:stable, "no-mutations-here"}
  end
end
