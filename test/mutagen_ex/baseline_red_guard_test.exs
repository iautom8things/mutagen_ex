defmodule MutagenEx.BaselineRedGuardTest do
  @moduledoc """
  Regression guard for the `:baseline_red` guard rail (mutagen-hcs.4).

  ## What this protects

  README known-limitation #1 historically claimed the `:baseline_red`
  guard rail "does not trip in production": coverage's `ExUnit.run/0`
  drains `ExUnit.Server` before baseline runs, `Code.require_file/1` is
  one-shot per path, so baseline's `ExUnit.run/0` was said to report
  `failures: 0` regardless of whether the cited tests are red. The
  mutagen-wrd.37 fix re-registers each cited module with
  `ExUnit.Server.add_module/2` before baseline's own run; this test
  locks that fix in against the REAL `ExUnit` / `ExUnit.Server` — not
  the `ExUnitFake` the rest of `baseline_test.exs` uses.

  ## Why a separate file from `baseline_test.exs`

  `MutagenEx.BaselineTest` drives `Baseline.run/1` through an
  `ExUnitFake` whose `run/0` returns a process-dictionary-seeded map. A
  fake can never observe the `ExUnit.Server`-drain hazard the README
  documented, because it never touches the real server. This file
  deliberately wires the production default seams (`MutagenEx.Test.ExUnit`
  ⇒ real `ExUnit`, `MutagenEx.Test.ExUnitServer` ⇒ real `ExUnit.Server`)
  so a regression in the re-registration path fails here.

  ## How the production hazard is reproduced

  The cited fixture modules live under `test/fixtures/` (ignored by the
  parent loader — see `mix.exs`) and are tagged
  `:mutagen_baseline_red_guard`, which `test/test_helper.exs` excludes
  from the default run so the deliberately-red fixture never surfaces as
  a top-level failure. We `Code.require_file/1` them once in
  `setup_all` — exactly as the production pipeline loads cited test
  files — then, per test:

    1. drain `ExUnit.Server` with a nested `ExUnit.run/0` (standing in
       for coverage's run), and
    2. hand the SAME module to `Baseline.run/1` via the `:test_modules`
       payload — exactly what `Mix.Tasks.Mutagen.phase_baseline/4`
       threads through.

  Both nested runs re-`include` the fixture tag (otherwise the global
  exclude would skip the cited module). A pre-`.37` baseline that did
  not re-register would see an empty registry and return
  `{:ok, %{failed: 0}}`; the red assertion below would then fail,
  surfacing the regression.

  Marked `async: false` because it reconfigures and drives the shared
  `ExUnit` instance.
  """

  use ExUnit.Case, async: false

  alias MutagenEx.Baseline
  alias MutagenEx.TestSelector.TestFilter

  @module_cfg %{async?: false, group: nil, parameterize: nil}
  @fixture_tag :mutagen_baseline_red_guard

  @red_fixture Path.expand("../fixtures/baseline_red_guard/red_cited_test.exs", __DIR__)
  @green_fixture Path.expand("../fixtures/baseline_red_guard/green_cited_test.exs", __DIR__)

  @red_module MutagenEx.BaselineRedGuardFixtures.RedCitedTest
  @green_module MutagenEx.BaselineRedGuardFixtures.GreenCitedTest

  setup_all do
    # Load both cited fixtures once. `require_file` fires the
    # `use ExUnit.Case` registration; a second `require_file` on the same
    # path is the cached no-op the README hazard is built on, so each test
    # below relies on `add_module/2` re-registration, not a fresh load.
    # The fixtures' `:mutagen_baseline_red_guard` moduletag is excluded by
    # the parent run, so the registration enqueued here is inert until a
    # nested run re-includes the tag.
    Code.require_file(@red_fixture)
    Code.require_file(@green_fixture)
    :ok
  end

  setup do
    # `ExUnit.Server` is process-global and shared with the parent suite.
    # Drain any modules a prior test left queued so each test's
    # "coverage drain" + baseline sequence starts from a known-empty
    # registry. The drain runs with the fixture tag included so it
    # actually consumes the cited module rather than skipping it.
    drain_once()

    # `ExUnit.run/0` leaves global config mutated. Restore a neutral
    # filter after each test so we don't leak include/exclude into other
    # suites sharing this ExUnit instance.
    on_exit(fn -> ExUnit.configure(include: [], exclude: [:test]) end)
    :ok
  end

  test "baseline_red fires against the real ExUnit.Server after a prior run drained it" do
    {{drain_result, baseline_result}, _io} =
      ExUnit.CaptureIO.with_io(fn ->
        # ---- Step 1: coverage-phase drain --------------------------------
        # Register the red module and consume it with a nested
        # `ExUnit.run/0`, mirroring how the coverage phase drains
        # `ExUnit.Server` before baseline ever runs.
        ExUnit.configure(include: [@fixture_tag], exclude: [:test])
        ExUnit.Server.add_module(@red_module, @module_cfg)
        drain = ExUnit.run()

        # ---- Step 2: production baseline ---------------------------------
        # `Baseline.run/1` with the production default seams. The
        # `:test_modules` payload re-registers the cited module with
        # `ExUnit.Server` before baseline's own `ExUnit.run/0`. The
        # registry is empty here (Step 1 drained it), so re-registration
        # is the load-bearing step. The TestFilter carries the same
        # include so baseline's `ExUnit.configure/1` runs the tagged
        # module.
        input = %{
          seed: 0,
          test_filter: %TestFilter{include: [@fixture_tag], exclude: [:test], files: []},
          test_modules: [{@red_module, @module_cfg}]
        }

        {drain, Baseline.run(input)}
      end)

    # Step 1 must actually have run the failing test — proving the module
    # ran and the registry was then drained.
    assert drain_result.failures >= 1,
           "expected the coverage-phase drain to run the red module; got #{inspect(drain_result)}"

    # Step 2 is the guard rail: after the drain, baseline must still
    # detect the red cited test via re-registration.
    assert {:error, :baseline_red, details} = baseline_result,
           "expected :baseline_red after re-registration; got #{inspect(baseline_result)}"

    assert details.failed >= 1
  end

  test "baseline stays green when the cited module passes (re-registration is not a false-positive)" do
    {{drain_result, baseline_result}, _io} =
      ExUnit.CaptureIO.with_io(fn ->
        ExUnit.configure(include: [@fixture_tag], exclude: [:test])
        ExUnit.Server.add_module(@green_module, @module_cfg)
        drain = ExUnit.run()

        input = %{
          seed: 0,
          test_filter: %TestFilter{include: [@fixture_tag], exclude: [:test], files: []},
          test_modules: [{@green_module, @module_cfg}]
        }

        {drain, Baseline.run(input)}
      end)

    assert drain_result.failures == 0
    assert {:ok, %{failed: 0}} = baseline_result
  end

  # Drain whatever modules are queued in `ExUnit.Server` with the fixture
  # tag included, discarding output. Used between tests to isolate
  # registry state.
  defp drain_once do
    ExUnit.CaptureIO.capture_io(fn ->
      ExUnit.configure(include: [@fixture_tag], exclude: [:test])
      ExUnit.run()
    end)
  end
end
