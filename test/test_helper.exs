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
# - `:mutagen_baseline_red_guard` tags the deliberately-red and -green
#   cited fixture modules under `test/fixtures/baseline_red_guard/`. They
#   are `Code.require_file/1`'d by `MutagenEx.BaselineRedGuardTest` and
#   driven only through that test's own nested `ExUnit.run/0` calls (which
#   re-`include` the tag). Excluding it here keeps the parent suite from
#   running the deliberately-red fixture as a spurious top-level failure.
#
# - `:cover_lifecycle` covers tests that manipulate the BEAM-wide
#   `:cover_server` singleton — they start/stop `:cover`, register a
#   sentinel under `:cover_server`, or call
#   `MutagenEx.CoverageRunner.run/1` (the documented singleton owner that
#   refuses to run when `:cover_server` is already registered). Under
#   `mix test --cover` the Mix harness owns `:cover_server` and has
#   cover-compiled the whole project before the suite starts, so these
#   tests cannot run as written: `CoverageRunner.run/1` correctly refuses
#   with `:cover_already_running`, and a test stopping `:cover` would
#   discard the harness's instrumentation (crashing the coverage reporter
#   with `Enum.EmptyError` because zero modules remain compiled). They run
#   on every normal `mix test`; only `--cover` excludes them.
cover_exclusions =
  if Process.whereis(:cover_server) do
    [:cover_lifecycle]
  else
    []
  end

ExUnit.start(
  exclude:
    [
      :e2e_slow,
      :spike,
      :downstream_integration,
      :archive_integration,
      :mutagen_baseline_red_guard
    ] ++ cover_exclusions
)
