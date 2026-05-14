defmodule MutagenEx.MixProject do
  use Mix.Project

  def project do
    [
      app: :mutagen_ex,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      # Lane fixture (test/fixtures/lane_project/**) is a self-contained
      # mini-mix-project; its `_test.exs` files exist only to be cited by
      # `mix mutagen --tests` from the end-to-end test driver, never run
      # directly by the parent project's `mix test`. Without this ignore,
      # the parent's loader picks up the fixture's `*_test.exs` files and
      # fails because the fixture modules (`LaneFixture.*`) aren't on the
      # parent's compile graph.
      test_load_filters: [
        fn path ->
          String.ends_with?(path, "_test.exs") and
            not String.starts_with?(path, "test/fixtures/lane_project/")
        end
      ],
      test_ignore_filters: [
        fn path -> String.starts_with?(path, "test/fixtures/") end
      ]
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {MutagenEx.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      # {:dep_from_hexpm, "~> 0.3.0"},
      # {:dep_from_git, git: "https://github.com/elixir-lang/my_dep.git", tag: "0.1.0"}
    ]
  end
end
