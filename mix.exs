defmodule MutagenEx.MixProject do
  use Mix.Project

  def project do
    [
      app: :mutagen_ex,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
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

  # Pin `mix test.integration` to MIX_ENV=test so the alias is usable
  # without an explicit `MIX_ENV=test` prefix (Mix otherwise errors with
  # "mix test is running in the dev environment").
  def cli do
    [preferred_envs: ["test.integration": :test]]
  end

  # `mix test.integration` runs the downstream-adoption integration suite
  # (test/integration/**) which is excluded from the default `mix test` run
  # via the `:downstream_integration` tag in `test/test_helper.exs`. These
  # tests boot a tmp Mix project and drive `mix mutagen` via
  # `System.cmd/3` to gate the runtime preamble contract
  # (`mutagen.cli.r14`). The dedicated `:downstream_integration` tag (vs.
  # the shared `:integration` tag) is intentional: pre-existing
  # in-process tests (beam_cache, mutation_runner, head_atom_dispatch)
  # carry `:integration` and must continue to run in the default lane.
  # The alias scopes to `test/integration` so it does not also pick up
  # the existing `:e2e_slow`-tagged suites under `test/mutagen_ex/`.
  defp aliases do
    [
      "test.integration": "test --include downstream_integration test/integration"
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      # `:telemetry` is the only runtime dependency. The mutation runner
      # dispatches events at well-defined points (enumeration_done,
      # baseline_done, coverage_done, site_started, site_completed,
      # run_completed) per `mutagen.mutation_pipeline.r15`; consumers
      # attach their own handlers. No metrics/exporter dependency — the
      # event surface is intentionally minimal.
      {:telemetry, "~> 1.0"}
    ]
  end
end
