defmodule LaneFixture.MixProject do
  @moduledoc """
  Mix project for the lane fixture used by `test/mutagen_ex/end_to_end_test.exs`.

  This file marks the lane fixture as a self-contained mini-project so the
  end-to-end test can `cd` here and drive the full `mix mutagen` pipeline
  against it without polluting the host project's compile graph.

  The host project (`mutagen_ex`) does NOT compile or load this `mix.exs`;
  it is present so a developer poking around can `cd test/fixtures/lane_project
  && mix compile` and inspect the fixture directly.
  """
  use Mix.Project

  def project do
    [
      app: :lane_fixture,
      version: "0.0.0",
      elixir: "~> 1.19",
      deps: []
    ]
  end

  def application do
    [extra_applications: []]
  end
end
