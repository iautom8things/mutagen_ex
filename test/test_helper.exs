# Tag-based exclusions for the default `mix test` run:
#
# - `:e2e_slow` drives the full `mix mutagen` pipeline against the lane
#   fixture and takes minutes each. Run explicitly via
#   `mix test --only e2e_slow`.
#
# - `:spike` covers the C1/C2 integration spikes under
#   `test/mutagen_ex/integration/`. They execute ~500 cover lifecycles
#   each `mix test` run and dominate wall-clock time. They are the gating
#   decision artifact for the in-process pipeline (see
#   `mutagen.decision.in_process_pipeline`) and must stay runnable, just
#   not on every default run. Run explicitly via
#   `mix test --only spike`. Override the C2 iteration count with
#   `MUTAGEN_SPIKE_ITERATIONS=<n>` (default `10`, set to `100` to
#   reproduce the original gating run).
#
# - `:downstream_integration` covers downstream-adoption integration
#   tests under `test/integration/` that boot a tmp Mix project, add
#   `mutagen_ex` as a `path:` dep, and drive `mix mutagen` via
#   `System.cmd/3`. These are the load-bearing regression gate for the
#   `mix mutagen` runtime preamble (see `mutagen.cli.r14`) but spawn a
#   child OS process per test and so are skipped by default. The tag is
#   intentionally distinct from the shared `:integration` tag used by
#   pre-existing in-process tests (e.g. beam_cache, mutation_runner,
#   head_atom_dispatch) so that excluding this lane does not silently
#   demote those tests out of the default `mix test` run. Run
#   explicitly via `mix test --include downstream_integration` or
#   `mix test.integration`.
#
# - `:archive_integration` covers archive-install adoption under
#   `test/integration/`. It builds and installs the local archive into a
#   scoped `MIX_ARCHIVES` directory, then drives `mix mutagen` from a
#   generated host project with no `:mutagen_ex` dependency declaration.
#   Run explicitly via `mix test --include archive_integration` or
#   `mix test.integration`.
#
# - `:self_mutation` covers the self-mutation dogfood under
#   `test/integration/`. It shadow-copies mutagen_ex's own source under a
#   rewritten namespace and drives `mix mutagen` against each high-value
#   module via `System.cmd/3` to produce a reproducible self-mutation score
#   (see `mutagen.decision.self_mutation_refused` for why the shadow copy is
#   required). It spawns a `mix mutagen` child process per target and is the
#   slowest suite in the project, so it is skipped by default. Run explicitly
#   via `mix test --include self_mutation` or `mix test.integration`.
ExUnit.start(
  exclude: [:e2e_slow, :spike, :downstream_integration, :archive_integration, :self_mutation]
)
