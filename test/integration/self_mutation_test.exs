Code.require_file("support/self_mutation_harness.exs", __DIR__)

defmodule MutagenEx.Integration.SelfMutationTest do
  @moduledoc """
  Self-mutation dogfood (mutagen-bqd.3).

  Proves `mutagen_ex` can produce a mutation score on its own high-value
  logic, working around `.spec/decisions/self_mutation_refused.md` by running
  `mix mutagen` against a shadow copy of mutagen_ex's own source whose module
  namespace is rewritten off the `MutagenEx.` prefix the self-mutation guard
  refuses. See `MutagenEx.Integration.SelfMutationHarness` for the mechanism
  and the per-target rationale (including why `cli` is excluded).

  This test gates the *harness*: that the shadow project builds, that
  `mix mutagen` runs against each target without aborting, and that it reports
  a non-trivial, mostly-killed mutation set — i.e. mutagen_ex's own tests do
  kill mutants in its own code. It is the executable companion to the README's
  cited self-mutation score (`## Efficacy on real codebases`).

  Tagged `:self_mutation` so the default `mix test` run skips it: like the
  other `test/integration/**` suites it boots a tmp Mix project and spawns an
  OS child process per target, so it is far slower than the in-process suite.
  Run explicitly via `mix test --include self_mutation` or
  `mix test.integration`.
  """

  use ExUnit.Case, async: false

  @moduletag :self_mutation
  # Each target spawns a `mix mutagen` child process that mutates and
  # re-tests; the full three-target sweep is minutes of wall-clock.
  @moduletag timeout: 900_000

  alias MutagenEx.Integration.SelfMutationHarness

  test "mutagen_ex produces a self-mutation score on its high-value modules" do
    %{targets: per_target, aggregate: aggregate} = SelfMutationHarness.score()

    assert length(per_target) == length(SelfMutationHarness.targets()),
           "expected one score per target, got: #{inspect(per_target)}"

    for t <- per_target do
      refute t.aborted,
             "target #{t.name} aborted (#{inspect(t.abort_reason)}); the mutation run did " <>
               "not complete — the shadow scope likely failed its baseline:\n#{inspect(t)}"

      assert is_integer(t.total) and t.total > 0,
             "target #{t.name} mutated nothing (total=#{inspect(t.total)}); the shadow " <>
               "scope produced no mutation sites:\n#{inspect(t)}"

      assert t.killed + t.survived <= t.total,
             "target #{t.name} bookkeeping is inconsistent:\n#{inspect(t)}"
    end

    assert aggregate.total > 0, "aggregate mutated nothing: #{inspect(aggregate)}"

    # The dogfood is only credible if mutagen_ex's own tests actually kill its
    # own mutants. A near-zero kill rate would mean the harness ran but proved
    # nothing. Assert a real (not perfect) floor so the test stays a signal
    # without becoming brittle to a single newly-surviving mutant. The
    # observed aggregate at authoring time was 46/79 (~0.58); the floor here
    # is deliberately well below that so a small kill-set drift does not flip
    # the gate red.
    assert aggregate.kill_rate >= 0.5,
           "aggregate kill rate #{inspect(aggregate.kill_rate)} is implausibly low for a " <>
             "self-mutation run; the harness likely mis-cited tests:\n#{inspect(aggregate)}"
  end
end
