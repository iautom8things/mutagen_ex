# `:e2e_slow` tags drive the full `mix mutagen` pipeline against the lane
# fixture and take minutes each. They are excluded from the default `mix
# test` run (which must stay under ~60s for the orchestrator's smoke
# gate). Run them explicitly via `mix test --only e2e_slow`.
ExUnit.start(exclude: [:e2e_slow])
