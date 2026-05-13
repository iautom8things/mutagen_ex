defmodule LaneFixture.RedBaselineTest do
  @moduledoc """
  Deliberately-failing test file for the baseline-red scenario.

  The end-to-end test drives `mix mutagen --tests <this file>` and asserts
  the pipeline aborts with `abort_reason: "baseline_red"` before any
  mutation runs. This module is NEVER cited together with the other
  per-module test files; it is a standalone red-baseline trigger.
  """

  use ExUnit.Case, async: false

  test "this test always fails — baseline-red trigger" do
    # The assertion is wrong on purpose so the baseline run fails. Per
    # mutagen.mutation_pipeline.r1, that failure aborts the pipeline
    # with abort_reason: :baseline_red before any mutation cycle starts.
    assert LaneFixture.Arith.add(2, 3) == 999
  end
end
