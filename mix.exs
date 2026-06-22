defmodule MutagenEx.MixProject do
  use Mix.Project

  def project do
    [
      app: :mutagen_ex,
      version: "0.1.0",
      elixir: "~> 1.19",
      description:
        "Mutation testing for Elixir — mutates a scope, runs cited tests per mutant, emits a JSON kill/survive report.",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      package: package(),
      aliases: aliases(),
      docs: docs(),
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
        fn path -> String.starts_with?(path, "test/fixtures/") end,
        # `test/support/*.exs` helpers are loaded on demand via
        # `Code.require_file/2` (not `elixirc_paths`), so they are not
        # `_test.exs` files and would otherwise trip the unmatched-file
        # warning.
        fn path -> String.starts_with?(path, "test/support/") end
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

  # Hex package metadata. The root `LICENSE` file backs the `:licenses` key.
  # A `:files` whitelist is intentionally deferred to a separate packaging
  # hygiene epic.
  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => "https://github.com/iautom8things/mutagen_ex"},
      maintainers: ["Manuel Zubieta"]
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
      "test.integration":
        "test --include downstream_integration --include archive_integration test/integration"
    ]
  end

  # ex_doc config. `main: "readme"` renders README.md as the landing page
  # rather than a module. Modules are grouped into mutators (the individual
  # AST mutation operators), pipeline facades (the injectable boundary
  # adapters under `MutagenEx.Pipeline`), and core (everything else — the
  # runner, enumerator, config, reporters, and supporting modules).
  defp docs do
    [
      main: "readme",
      extras: ["README.md", "CHANGELOG.md"],
      groups_for_modules: [
        Mutators: [~r/^MutagenEx\.Mutators/],
        "Pipeline Facades": [~r/^MutagenEx\.Pipeline/],
        Core: [
          MutagenEx.MutationRunner,
          MutagenEx.MutationRunner.MutationLoop,
          MutagenEx.MutationEnumerator,
          MutagenEx.Baseline,
          MutagenEx.CoverageRunner,
          MutagenEx.Config,
          MutagenEx.Cli,
          MutagenEx.ScopeResolver,
          MutagenEx.Ast,
          MutagenEx.AstCache,
          MutagenEx.BeamCache,
          MutagenEx.JsonReporter,
          MutagenEx.JsonStreamer,
          MutagenEx.JsonPath,
          MutagenEx.Progress,
          MutagenEx.Telemetry,
          MutagenEx.TestModuleDiscovery,
          MutagenEx.TestSelector,
          MutagenEx.Types
        ]
      ]
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
      {:telemetry, "~> 1.0"},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end
end
