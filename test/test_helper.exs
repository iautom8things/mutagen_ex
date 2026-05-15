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
ExUnit.start(exclude: [:e2e_slow, :spike])
