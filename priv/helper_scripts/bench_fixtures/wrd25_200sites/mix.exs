defmodule Wrd25Bench.MixProject do
  @moduledoc """
  Mix project for the `wrd25_200sites` bench fixture.

  Marks the fixture as a self-contained mini-project so:

    * `test/mutagen_ex/determinism_test.exs` (S1+) can `cd` here and
      drive `mix mutagen` over a non-trivial corpus while keeping the
      byte-identical-output contract isolated from the host project.
    * `priv/helper_scripts/bench_ast_perf.exs` (S6) can run the AST
      bench harness end-to-end against this tree.

  The host project (`mutagen_ex`) does NOT compile or load this
  `mix.exs`; it sits here so a developer poking around can `cd
  priv/helper_scripts/bench_fixtures/wrd25_200sites && mix compile`
  and inspect the fixture directly.
  """
  use Mix.Project

  def project do
    [
      app: :wrd25_bench,
      version: "0.0.0",
      elixir: "~> 1.19",
      deps: []
    ]
  end

  def application do
    [extra_applications: []]
  end
end
