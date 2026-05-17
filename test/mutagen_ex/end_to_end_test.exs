defmodule MutagenEx.EndToEndTest do
  @moduledoc """
  S7 end-to-end integration: drives the full `mix mutagen` pipeline
  against the lane fixture at `test/fixtures/lane_project/` and asserts
  the outputs match the contracts in `mutagen.mutation_pipeline.spec.md`
  and `mutagen.json_schema.spec.md`.

  ## What this file proves

  Each test in this file invokes `Mix.Tasks.Mutagen.run/2` against one
  scope target in the lane fixture and asserts on the resulting JSON:

  - Scenario 1: arith.ex → simple-mutator categories produce mutations
    (`mutagen.mutation_pipeline.r5`, `mutagen.json_schema.r3/r4`).
    Pins at least one `arith` mutator in `results`.
  - Scenario 2: decisions.ex → compare/boolean/literal/case_drop produce
    mutations with no `:compile_error` in `results`
    (`mutagen.mutation_pipeline.r5`). Pins `compare` AND `boolean`
    individually as the floor for the "all four simple mutator
    categories" gate the ticket names. The `literal` floor lives in
    its own scenario (2a) tagged `:skip` pending bw mutagen-wrd.15
    (DISCOVERY-E: Literal mutator does not match parsed AST).
  - Scenario 2a: decisions.ex `literal` mutator floor — `@tag :skip`
    pending bw mutagen-wrd.15. The literal mutator's `match?/1` only
    catches the bare value (`0`, `1`, etc.); bare atomic literals
    carry no line metadata in the parsed AST so the enumerator
    drops them. Fix belongs in lib/.
  - Scenario 3: result_tuples.ex → Elixir-flavored mutators (result_tuple)
    cleanly produce sites that EITHER kill OR skip, never
    `:compile_error` (verification target).
  - Scenario 3a: pipelined.ex → `pipeline` mutator produces sites.
  - Scenario 3b: guarded.ex → `guard_drop` mutator produces sites.
  - Scenario 3c: withblock.ex → `with_swap` mutator produces sites.
  - Scenario 3d: withblock.ex → `else_removal` mutator produces sites.
  - Scenario 4 (`@tag :timeout_scenario`): infinite loop classifies as
    `:timeout` (`r4`/`r5`).
  - Scenario 5 (`@tag :baseline_red_scenario`): baseline-red abort (`r1`).
  - Scenario 6 (`@tag :zero_coverage_scenario`): a scope with no
    mutator-eligible sites produces a `no_mutation_candidates` warning.
  - Scenario 7 (`@tag :ecto_user_scenario`, `@tag :skip`): bytecode-
    identical restore after a full mutation pass on the C1-analogue
    fixture (Spike I invariants, `r6`/`r11`). Skipped pending
    bw mutagen-wrd.13 (MutationLoop brutal_kill / Code.Server hardening)
    — the EctoUser hand-rolled DSL stresses cover-instrumentation
    in a way the current production code does not survive (a baseline
    test fails before any mutation runs).
  - Scenario 8 (`@tag :macro_holder_scenario`): `state_drift_warning`
    entry naming `LaneFixture.MacroHolder`.

  All scenarios except 7 run as part of the `e2e_slow`-only suite.
  Run via `mix test --only e2e_slow`. Scenarios 4 and 7 keep their
  `@tag` aliases for individual invocation via `mix test --only
  <tag_name>`.

  ## Test architecture

  The lane fixture is a self-contained mini-project. The end-to-end test:

  1. Pre-compiles every `lib/lane_fixture/*.ex` file into a tmp ebin so
     the modules are loaded with a real `.beam` path
     (`:cover.compile_beam/1` requirement).
  2. `cd`s into `test/fixtures/lane_project/` for each scenario so
     `Path.wildcard("lib/**/*.ex")` and relative test paths resolve to
     fixture-local files.
  3. Invokes the pipeline via `Mix.Tasks.Mutagen.run/2` with a custom
     `:io` collaborator that captures `{iodata, exit_code}` instead of
     calling `System.halt/1`. The `:coverage` collaborator wraps the
     production one to inject the `Code.compile_file/1` re-evaluation
     so the `use ExUnit.Case` `__after_compile__` side effect re-fires
     on the second scenario that cites the same test file (the
     `Code.require_file/1` cache hazard documented in
     `mutagen.mutation_pipeline.r10`). The `:tests`, `:baseline`, and
     `:mutation` collaborators are the production ones
     (`MutagenEx.TestSelector.resolve/2` per mutagen-wrd.11,
     `MutagenEx.Baseline.run/1` per mutagen-wrd.37,
     `MutagenEx.MutationRunner.run/1` per mutagen-wrd.12).
  4. Decodes the captured JSON and asserts shape and outcome.

  Per-scenario state isolation (`reset_e2e_state!/1`) keeps every
  scenario independent of execution order:
    * `:cover.stop/0` to de-instrument any modules left over from
      a prior scenario;
    * `:code.purge/1` + `:code.load_file/1` on every lane-fixture
      module to restore a disk-resident `.beam` (cover's precondition);
    * a fresh `Code.compile_file/1` of every cited test file per phase,
      which re-fires the `use ExUnit.Case` `__after_compile__` hook so
      `ExUnit.Server` re-registers the cited modules (`Code.require_file/1`
      caches by path and would otherwise no-op on the second scenario).

  Marked `async: false` because the pipeline reconfigures the running
  ExUnit instance via `ExUnit.configure/1` and `:cover` is a global
  resource.

  ## Golden-fixture compare (`mutagen.json_schema.r9` / S6)

  The ticket's merge gate requires "each scenario maps to a golden
  fixture and matches byte-for-byte". The captured JSON contains a
  handful of fields that are inherently non-deterministic per run:

    * `meta.elixir_version`, `meta.otp_version` — host-toolchain values.
    * `meta.exunit_seed` — random by default; pinned to `0` by the e2e
      driver but still environment-state.
    * `mutation.results[].warnings` — contain absolute-path text in the
      cover-recompile warning (`/var/folders/…/Elixir.LaneFixture.…`).
    * `coverage.covered_lines.*` — encoded as binary line bitmaps; the
      bytes are stable per source but legible only after decoding.

  Rather than fight per-host drift, the e2e driver normalises these to
  stable placeholders before the byte-equal compare against the golden
  in `test/mutagen_ex/golden/end_to_end_<scenario>.json` (S6 precedent
  in `test/mutagen_ex/json_reporter_golden_test.exs`). Normalisation
  rules — `normalize_for_golden/1`:

    1. `meta.elixir_version`, `meta.otp_version`, `meta.tool_version`
       → replaced with `\"<NORMALIZED>\"`.
    2. `mutation.results[].warnings` → mapped to the count
       (`%{\"count\" => N}`) so absolute paths in cover-warning text
       do not break the compare.
    3. `coverage.covered_lines` → values replaced with the bitmap's
       byte length so the shape is asserted without bit-level drift.
    4. Recursive: same rules applied to nested objects.

  Set `REGEN=1 mix test --only e2e_slow` to refresh every golden in
  place (mirrors `MutagenEx.JsonReporterGoldenTest`'s convention).
  """

  use ExUnit.Case, async: false

  # `:e2e_slow` is excluded from the default `mix test` run via
  # `test/test_helper.exs` — every scenario in this module spins up the
  # full `mix mutagen` pipeline against the lane fixture, which takes
  # tens of seconds per scenario. Run via `mix test --only e2e_slow`.
  @moduletag :e2e_slow
  @moduletag :integration
  @moduletag timeout: 600_000

  @lane_project_dir Path.expand("../fixtures/lane_project", __DIR__)
  @lane_lib_dir Path.join(@lane_project_dir, "lib/lane_fixture")

  @lane_fixture_files [
    "arith.ex",
    "decisions.ex",
    "guarded.ex",
    "pipelined.ex",
    "result_tuples.ex",
    "macro_holder.ex",
    "struct_holder.ex",
    "no_defs.ex",
    "infinite_looper.ex",
    "ecto_user.ex",
    "withblock.ex"
  ]

  # ---------------------------------------------------------------------------
  # Setup
  # ---------------------------------------------------------------------------

  setup_all do
    ensure_cover_loadable!()

    ebin =
      Path.join(System.tmp_dir!(), "mutagen_ex_lane_#{System.unique_integer([:positive])}")

    File.mkdir_p!(ebin)
    Code.append_path(ebin)

    prior_opts = Code.compiler_options()
    Code.compiler_options(debug_info: true)

    _ =
      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        Process.put(:lane_compile_result, compile_lane_fixture(ebin))
      end)

    {modules, pre_md5} = Process.get(:lane_compile_result)

    Code.compiler_options(prior_opts)

    on_exit(fn ->
      Code.delete_path(ebin)
      File.rm_rf!(ebin)
      Process.delete(:lane_compile_result)
    end)

    {:ok, ebin: ebin, compiled_modules: modules, pre_md5: pre_md5}
  end

  setup ctx do
    reset_e2e_state!(ctx)

    pre_hashes =
      for f <- @lane_fixture_files, into: %{} do
        path = Path.join(@lane_lib_dir, f)
        {f, :crypto.hash(:sha256, File.read!(path))}
      end

    on_exit(fn -> assert_lane_tree_unmodified!(pre_hashes) end)

    {:ok, Map.put(ctx, :pre_hashes, pre_hashes)}
  end

  # Full per-scenario reset of every piece of mutable state the pipeline
  # touches, so the e2e scenarios are independent of execution order.
  # Steps:
  #
  # 1. `:cover.stop/0` — defensive; if a prior scenario left cover
  #    instrumented modules in place, this de-instruments them and reloads
  #    the originals from the code path. Wrapped in try/rescue/catch so
  #    a never-started cover is a no-op.
  # 2. Reload every lane-fixture module from disk via `:code.purge/1` +
  #    `:code.load_file/1`. Even if cover.stop's reload-originals path
  #    succeeded, this is a belt-and-braces refresh so `:code.which/1`
  #    returns the disk-resident `.beam` path (cover.compile_beam/1's
  #    precondition) before the next scenario starts.
  # 3. Drain `ExUnit.Server` back to integer-`:loaded` state if the
  #    previous scenario left it in `:done` after its nested
  #    `ExUnit.run/0`. Calling `take_async_modules` / `take_sync_modules`
  #    is how the runner itself drains the server (see
  #    `ExUnit.Runner.run/2`); from outside the runner this is harmless
  #    when the state is already integer.
  # 4. Reset Mix.Project state if a prior scenario left it dirty (the
  #    pipeline calls `Mix.Project.config/0`; rerunning under the same
  #    project is fine, but defensive reset costs nothing).
  defp reset_e2e_state!(ctx) do
    # Step 1: stop cover.
    try do
      apply(:cover, :stop, [])
    rescue
      _ -> :ok
    catch
      _, _ -> :ok
    end

    # Step 2: re-load lane fixture modules from disk.
    case Map.fetch(ctx, :compiled_modules) do
      {:ok, modules} when is_list(modules) ->
        Enum.each(modules, fn mod ->
          _ = :code.purge(mod)
          _ = :code.delete(mod)
          _ = :code.load_file(mod)
        end)

      _ ->
        :ok
    end

    # Step 3: clear any leftover collaborator-context flags in the
    # process dictionary so each scenario starts clean.
    #
    # Note on ExUnit.Server state: we deliberately do NOT call
    # `ExUnit.Server.take_async_modules/1` or `take_sync_modules/0` here,
    # because the PARENT `ExUnit.run/0` (the suite that's running this
    # test module) is itself the runner waiting on those calls. Reaching
    # past it from inside a setup either races the parent's drain (see
    # `ExUnit.Server.handle_call({:take_async_modules, _}, ...)`'s
    # `waiting: nil` precondition) or crashes the server when state shape
    # doesn't match. Instead, the per-scenario nested `ExUnit.run/0`
    # inside `run_pipeline!/1` does its own take cycle and leaves the
    # server's `loaded` field back at an integer (per
    # `ExUnit.Server.handle_call(:take_sync_modules)` line 83) — so by
    # the time the next setup runs, the server already accepts
    # add_module again. The `prime_exunit_server!` helper called from
    # the baseline/coverage collaborators reissues `modules_loaded(false)`
    # which is a no-op against integer state and the `:done`-state
    # short-circuit (server.ex line 108), making the priming safe to
    # call any number of times.
    Process.delete(:e2e_capture_target)
    Process.delete(:e2e_capture_ref)

    :ok
  end

  # ---------------------------------------------------------------------------
  # Scenarios that run as part of the default suite
  # ---------------------------------------------------------------------------

  describe "Scenario 1: simple-mutator categories produce mutations (arith.ex)" do
    test "arith mutations land in results with the full JSON shape", _ctx do
      json =
        run_pipeline!([
          "--scope",
          "lib/lane_fixture/arith.ex",
          "--tests",
          "test/lane_fixture/arith_test.exs",
          "--timeout-ms",
          "2000"
        ])

      # mutagen.json_schema.r1: version is the literal "1".
      assert json["version"] == "1"

      # mutagen.json_schema.r2: aborted: false on full success;
      # abort_reason is nil.
      assert json["aborted"] == false,
             "expected non-aborted run; got abort_reason=#{inspect(json["abort_reason"])}, warnings=#{inspect(json["warnings"])}"

      assert json["abort_reason"] == nil

      # mutagen.json_schema.r3: mutation block has every subfield.
      mutation = json["mutation"]
      assert is_map(mutation)
      assert is_integer(mutation["total"])
      assert is_integer(mutation["completed"])
      assert is_integer(mutation["killed"])
      assert is_integer(mutation["survived"])
      assert is_integer(mutation["timeout"])
      assert is_integer(mutation["compile_error"])
      assert is_list(mutation["results"])
      assert is_list(mutation["skipped"])
      assert is_list(mutation["compile_errors"])
      assert is_map(mutation["state_drift_warning"])

      # mutagen.json_schema.r4: every result has the full set of fields.
      Enum.each(mutation["results"], fn r ->
        assert is_binary(r["id"])
        assert is_binary(r["file"])
        assert is_integer(r["line"])
        assert is_integer(r["column"])
        assert is_binary(r["mutator"])
        assert is_binary(r["before"])
        assert is_binary(r["after"])
        assert r["status"] in ["killed", "survived", "timeout", "error"]
        assert is_boolean(r["tainted_predecessors"])
        assert is_list(r["warnings"])
      end)

      # The Verification target: simple-mutator categories produce
      # mutations on arith.ex. At least one `arith` mutator must have
      # actually LANDED in `results` — appearing only in `compile_errors`
      # or `skipped` is a weaker signal that the bounce audit
      # specifically pinned out (per the iteration-2 bounce comment on
      # this ticket, item 2).
      arith_results =
        Enum.filter(mutation["results"], fn r -> r["mutator"] == "arith" end)

      assert arith_results != [],
             "expected at least one arith mutator landed in results against arith.ex; " <>
               "got results=#{inspect(Enum.map(mutation["results"], &Map.take(&1, ["mutator", "status"])))}, " <>
               "skipped=#{inspect(Enum.map(mutation["skipped"], & &1["mutator"]))}, " <>
               "compile_errors=#{inspect(Enum.map(mutation["compile_errors"], & &1["mutator"]))}"

      # mutagen.mutation_pipeline.r5: :compile_error sites do NOT
      # appear in `results`; they live in `compile_errors`.
      refute Enum.any?(mutation["results"], fn r -> r["status"] == "compile_error" end),
             "no result entry should have status :compile_error (must live in compile_errors)"

      assert_e2e_golden!("scenario_1_arith", json)
    end
  end

  describe "Scenario 2: decisions module exercises compare/boolean/literal" do
    test "multi-mutator coverage on decisions.ex", _ctx do
      json =
        run_pipeline!([
          "--scope",
          "lib/lane_fixture/decisions.ex",
          "--tests",
          "test/lane_fixture/decisions_test.exs",
          "--timeout-ms",
          "2000"
        ])

      assert json["version"] == "1"

      assert json["aborted"] == false,
             "expected non-aborted run; got JSON=#{inspect(json, limit: :infinity)}"

      mutation = json["mutation"]

      site_mutators =
        mutation["results"]
        |> Enum.map(& &1["mutator"])
        |> MapSet.new()
        |> MapSet.union(
          mutation["skipped"]
          |> Enum.map(& &1["mutator"])
          |> MapSet.new()
        )
        |> MapSet.union(
          mutation["compile_errors"]
          |> Enum.map(& &1["mutator"])
          |> MapSet.new()
        )

      # Per the iteration-2 bounce audit, item 2: the ticket's
      # Verification section names "all four simple mutator categories"
      # — arith (covered by Scenario 1) plus compare, boolean, literal
      # (this scenario). The audit asked for `Enum.all?` on
      # compare/boolean/literal. Per-mutator asserts surface a missing
      # category with a clear name.
      #
      # The `literal` floor is hoisted out to its own scenario (2a,
      # `@tag :skip`) because production's `literal` mutator does not
      # appear against any current fixture (bw mutagen-wrd.15 / DISCOVERY-E:
      # bare atomic literals carry no line metadata in the parsed AST so
      # the enumerator's coverage filter drops them). Keeping the
      # `literal` assert in this scenario would fail the test before
      # the golden compare, masking the compare/boolean signal. The
      # split honours the audit's "no silent weakening" + "discovery,
      # not skip" framework: literal IS asserted, in its own scenario,
      # with a bw reference, in the same posture as Scenario 7.
      assert MapSet.member?(site_mutators, "compare"),
             "expected at least one `compare` site on decisions.ex; got #{inspect(site_mutators)}"

      assert MapSet.member?(site_mutators, "boolean"),
             "expected at least one `boolean` site on decisions.ex; got #{inspect(site_mutators)}"

      # No `:compile_error` in `results` (r5 surface).
      refute Enum.any?(mutation["results"], &(&1["status"] == "compile_error"))

      assert_e2e_golden!("scenario_2_decisions", json)
    end
  end

  describe "Scenario 2a (solo): decisions.ex `literal` mutator floor (bw mutagen-wrd.16)" do
    # bw mutagen-wrd.16 fixed the literal-mutator floor: the enumerator
    # now threads each AST node's ambient `:line` (the nearest enclosing
    # 3-tuple's metadata) downward as it walks, so bare atomic literals
    # — the `0` in `n > 0`, the `1` in `do: 1`, case-clause-head literals
    # like `0 -> :zero` — are attributed to the parent operator/clause-
    # head's source line. The `is_nil(line) -> acc` filter in
    # `try_one_mutator/5` no longer drops them on lane fixtures where
    # `Code.string_to_quoted/2` leaves the literals bare (Elixir 1.19.5).
    @tag :literal_floor_scenario
    test "literal mutator lands at least one site on decisions.ex", _ctx do
      json =
        run_pipeline!([
          "--scope",
          "lib/lane_fixture/decisions.ex",
          "--tests",
          "test/lane_fixture/decisions_test.exs",
          "--timeout-ms",
          "2000"
        ])

      mutation = json["mutation"]

      site_mutators =
        mutation["results"]
        |> Enum.map(& &1["mutator"])
        |> MapSet.new()
        |> MapSet.union(
          mutation["skipped"]
          |> Enum.map(& &1["mutator"])
          |> MapSet.new()
        )
        |> MapSet.union(
          mutation["compile_errors"]
          |> Enum.map(& &1["mutator"])
          |> MapSet.new()
        )

      assert MapSet.member?(site_mutators, "literal"),
             "expected at least one `literal` site on decisions.ex; got #{inspect(site_mutators)}"
    end
  end

  describe "Scenario 3: result_tuples.ex (Elixir-flavored mutator) avoids :compile_error" do
    test "result_tuple sites kill or skip cleanly, never compile-error in results", _ctx do
      json =
        run_pipeline!([
          "--scope",
          "lib/lane_fixture/result_tuples.ex",
          "--tests",
          "test/lane_fixture/result_tuples_test.exs",
          "--timeout-ms",
          "2000"
        ])

      assert json["aborted"] == false
      mutation = json["mutation"]

      # Verification target: "the six Elixir-flavored mutators produce
      # mutations on their respective modules and EITHER kill cleanly OR
      # record as :skipped with reason — never :compile_error flakes."
      assert Enum.all?(mutation["results"], &(&1["status"] != "compile_error")),
             "Elixir-flavored mutators should never produce :compile_error in results"

      Enum.each(mutation["skipped"], fn s ->
        assert is_binary(s["site_id"])
        assert is_binary(s["mutator"])
        assert is_binary(s["reason"])
      end)

      assert_e2e_golden!("scenario_3_result_tuples", json)
    end
  end

  # ---------------------------------------------------------------------------
  # Scenarios covering the remaining Elixir-flavored mutators
  # (`with_swap`, `pipeline`, `else_removal`, `guard_drop`). Each
  # follows Scenario 3's shape: the cited mutator name must appear in
  # `results` or `skipped`, `:compile_error` must not appear in
  # `results`, and skipped entries must carry `site_id`/`mutator`/
  # `reason`.
  # ---------------------------------------------------------------------------

  describe "Scenario 3a: pipelined.ex exercises the `pipeline` mutator" do
    test "pipeline reorder sites kill or skip cleanly, never compile-error in results", _ctx do
      json =
        run_pipeline!([
          "--scope",
          "lib/lane_fixture/pipelined.ex",
          "--tests",
          "test/lane_fixture/pipelined_test.exs",
          "--timeout-ms",
          "2000"
        ])

      assert json["aborted"] == false,
             "expected non-aborted run; got JSON=#{inspect(json, limit: :infinity)}"

      mutation = json["mutation"]

      pipeline_sites =
        Enum.filter(mutation["results"], &(&1["mutator"] == "pipeline")) ++
          Enum.filter(mutation["skipped"], &(&1["mutator"] == "pipeline"))

      assert pipeline_sites != [],
             "expected at least one `pipeline` site against pipelined.ex; " <>
               "got results=#{inspect(Enum.map(mutation["results"], & &1["mutator"]))}, " <>
               "skipped=#{inspect(Enum.map(mutation["skipped"], & &1["mutator"]))}"

      assert Enum.all?(mutation["results"], &(&1["status"] != "compile_error")),
             "the pipeline mutator must never produce :compile_error in results"

      Enum.each(mutation["skipped"], fn s ->
        assert is_binary(s["site_id"])
        assert is_binary(s["mutator"])
        assert is_binary(s["reason"])
      end)

      assert_e2e_golden!("scenario_3a_pipelined", json)
    end
  end

  describe "Scenario 3b: guarded.ex exercises the `guard_drop` mutator" do
    test "guard_drop sites kill or skip cleanly, never compile-error in results", _ctx do
      json =
        run_pipeline!([
          "--scope",
          "lib/lane_fixture/guarded.ex",
          "--tests",
          "test/lane_fixture/guarded_test.exs",
          "--timeout-ms",
          "2000"
        ])

      assert json["aborted"] == false,
             "expected non-aborted run; got JSON=#{inspect(json, limit: :infinity)}"

      mutation = json["mutation"]

      guard_drop_sites =
        Enum.filter(mutation["results"], &(&1["mutator"] == "guard_drop")) ++
          Enum.filter(mutation["skipped"], &(&1["mutator"] == "guard_drop"))

      assert guard_drop_sites != [],
             "expected at least one `guard_drop` site against guarded.ex; " <>
               "got results=#{inspect(Enum.map(mutation["results"], & &1["mutator"]))}, " <>
               "skipped=#{inspect(Enum.map(mutation["skipped"], & &1["mutator"]))}"

      assert Enum.all?(mutation["results"], &(&1["status"] != "compile_error")),
             "the guard_drop mutator must never produce :compile_error in results"

      Enum.each(mutation["skipped"], fn s ->
        assert is_binary(s["site_id"])
        assert is_binary(s["mutator"])
        assert is_binary(s["reason"])
      end)

      assert_e2e_golden!("scenario_3b_guarded", json)
    end
  end

  describe "Scenario 3c: withblock.ex exercises the `with_swap` mutator" do
    test "with_swap sites kill or skip cleanly, never compile-error in results", _ctx do
      json =
        run_pipeline!([
          "--scope",
          "lib/lane_fixture/withblock.ex",
          "--tests",
          "test/lane_fixture/withblock_test.exs",
          "--timeout-ms",
          "2000"
        ])

      assert json["aborted"] == false,
             "expected non-aborted run; got JSON=#{inspect(json, limit: :infinity)}"

      mutation = json["mutation"]

      with_swap_sites =
        Enum.filter(mutation["results"], &(&1["mutator"] == "with_swap")) ++
          Enum.filter(mutation["skipped"], &(&1["mutator"] == "with_swap"))

      assert with_swap_sites != [],
             "expected at least one `with_swap` site against withblock.ex; " <>
               "got results=#{inspect(Enum.map(mutation["results"], & &1["mutator"]))}, " <>
               "skipped=#{inspect(Enum.map(mutation["skipped"], & &1["mutator"]))}"

      assert Enum.all?(mutation["results"], &(&1["status"] != "compile_error")),
             "the with_swap mutator must never produce :compile_error in results"

      Enum.each(mutation["skipped"], fn s ->
        assert is_binary(s["site_id"])
        assert is_binary(s["mutator"])
        assert is_binary(s["reason"])
      end)

      assert_e2e_golden!("scenario_3c_withblock_with_swap", json)
    end
  end

  describe "Scenario 3d: withblock.ex exercises the `else_removal` mutator" do
    test "else_removal sites kill or skip cleanly, never compile-error in results", _ctx do
      json =
        run_pipeline!([
          "--scope",
          "lib/lane_fixture/withblock.ex",
          "--tests",
          "test/lane_fixture/withblock_test.exs",
          "--timeout-ms",
          "2000"
        ])

      assert json["aborted"] == false,
             "expected non-aborted run; got JSON=#{inspect(json, limit: :infinity)}"

      mutation = json["mutation"]

      else_removal_sites =
        Enum.filter(mutation["results"], &(&1["mutator"] == "else_removal")) ++
          Enum.filter(mutation["skipped"], &(&1["mutator"] == "else_removal"))

      assert else_removal_sites != [],
             "expected at least one `else_removal` site against withblock.ex; " <>
               "got results=#{inspect(Enum.map(mutation["results"], & &1["mutator"]))}, " <>
               "skipped=#{inspect(Enum.map(mutation["skipped"], & &1["mutator"]))}"

      assert Enum.all?(mutation["results"], &(&1["status"] != "compile_error")),
             "the else_removal mutator must never produce :compile_error in results"

      Enum.each(mutation["skipped"], fn s ->
        assert is_binary(s["site_id"])
        assert is_binary(s["mutator"])
        assert is_binary(s["reason"])
      end)

      assert_e2e_golden!("scenario_3d_withblock_else_removal", json)
    end
  end

  # ---------------------------------------------------------------------------
  # Solo-tagged scenarios (see module doc for the production gap each
  # one exposes; each passes when run individually)
  # ---------------------------------------------------------------------------

  describe "Scenario 4 (solo): infinite_looper produces :timeout classification" do
    @tag :timeout_scenario
    @tag timeout: 120_000
    test "case_drop / arith on the recursive descent yields :timeout", _ctx do
      json =
        run_pipeline!([
          "--scope",
          "lib/lane_fixture/infinite_looper.ex",
          "--tests",
          "test/lane_fixture/infinite_looper_test.exs",
          "--timeout-ms",
          "1000"
        ])

      assert json["aborted"] == false
      mutation = json["mutation"]

      any_timeout =
        Enum.any?(mutation["results"], fn r -> r["status"] == "timeout" end)

      assert any_timeout,
             "expected at least one :timeout result on infinite_looper.ex; got " <>
               inspect(Enum.map(mutation["results"], &Map.take(&1, ["mutator", "status"])))

      results = mutation["results"]

      timeout_index =
        Enum.find_index(results, fn r -> r["status"] == "timeout" end)

      successor_idx = if timeout_index, do: timeout_index + 1, else: nil

      if is_integer(successor_idx) and successor_idx < length(results) do
        successor = Enum.at(results, successor_idx)

        assert successor["tainted_predecessors"] == true,
               "result immediately after :timeout must carry tainted_predecessors: true; got #{inspect(successor)}"
      end

      assert_e2e_golden!("scenario_4_infinite_looper", json)
    end
  end

  describe "Scenario 5 (solo): baseline-red abort" do
    @tag :baseline_red_scenario
    test "pipeline aborts with abort_reason: baseline_red", _ctx do
      # mutagen-wrd.37 regression coverage: this scenario routes through
      # the production `MutagenEx.Baseline` module (no
      # `BaselineCollaborator` wrapper). The bug being guarded against:
      # coverage's `ExUnit.run/0` consumes the cited module from
      # `ExUnit.Server`'s registry; baseline's `Code.require_file/1` on
      # the same path is a cached no-op (so `use ExUnit.Case`'s
      # `__after_compile__` does NOT re-fire); without the production
      # `ExUnit.Server.add_module/2` re-registration, baseline's own
      # `ExUnit.run/0` would silently observe `%{total: 0,
      # failures: 0}` and miss the deliberately-failing cited test.
      #
      # Falsifier: if the production baseline re-regresses, the
      # `baseline.failed >= 1` assertion fails (zero failures → no
      # `:baseline_red` → `aborted` flips to `false`).
      json =
        run_pipeline!([
          "--scope",
          "lib/lane_fixture/arith.ex",
          "--tests",
          "test/lane_fixture/red_baseline_test.exs",
          "--timeout-ms",
          "2000"
        ])

      assert json["version"] == "1"

      assert json["aborted"] == true,
             "expected aborted run; got JSON=#{inspect(json, limit: :infinity)}"

      assert json["abort_reason"] == "baseline_red"

      # r5: every abnormal exit emits a document of the SAME schema.
      # Sub-blocks that never ran are `null`.
      assert json["mutation"] == nil

      # r1: the baseline phase recorded at least one failure. The
      # `failed` integer is produced by ExUnit's own counter and is
      # the load-bearing gauge that the orchestrator routes off
      # (`failures > 0` → `:baseline_red`). The `failures` *detail*
      # list is populated by a separately-wired `:failure_collector`
      # seam (defaults to a no-op `[]` per `lib/mutagen_ex/baseline.ex`
      # line 151) — its emptiness in the default wiring is correct
      # behaviour, not a regression.
      assert is_map(json["baseline"])
      assert is_integer(json["baseline"]["failed"])
      assert json["baseline"]["failed"] >= 1
      assert is_list(json["baseline"]["failures"])

      assert_e2e_golden!("scenario_5_baseline_red", json)
    end
  end

  describe "Scenario 6 (solo): zero-coverage / zero-mutation" do
    @tag :zero_coverage_scenario
    test "scope with no mutator-eligible sites finishes cleanly", _ctx do
      json =
        run_pipeline!([
          "--scope",
          "lib/lane_fixture/no_defs.ex",
          "--tests",
          "test/lane_fixture/no_defs_test.exs",
          "--timeout-ms",
          "2000"
        ])

      assert json["version"] == "1"
      assert json["aborted"] == false
      mutation = json["mutation"]

      assert mutation["total"] == 0
      assert mutation["completed"] == 0
      assert mutation["results"] == []
      assert mutation["compile_errors"] == []
      assert mutation["kill_rate"] == nil

      no_candidates_warning =
        Enum.any?(json["warnings"], fn w ->
          w =~ "no_mutation_candidates" and w =~ "NoDefs"
        end)

      assert no_candidates_warning,
             "expected a no_mutation_candidates warning naming NoDefs; got #{inspect(json["warnings"])}"

      assert_e2e_golden!("scenario_6_zero_coverage", json)
    end
  end

  describe "Scenario 7 (solo): EctoUser bytecode-identical restore (Spike I invariants)" do
    # Un-skipped in mutagen-wrd.32 after the mutagen-wrd.19 spike
    # (Option B disposition) confirmed the prior `:cover` + Ecto-DSL
    # framing was wrong: every macro-injected callback on
    # `LaneFixture.EctoUser` survives the full
    # `:cover.compile_beam/1` -> `:cover.stop/0` -> `:code.purge/1` ->
    # `:code.load_file/1` cycle byte-for-byte. The baseline-red was a
    # fixture-test assertion bug in `ecto_user_test.exs` (a
    # `Keyword.get_values/2` over a `persist: true` attribute returns a
    # list-of-lists), now fixed.
    @tag :ecto_user_scenario
    @tag timeout: 120_000
    test "after full mutation pass, source and bytecode are identical (r6, r11)", ctx do
      for mod <- [LaneFixture.EctoUser, LaneFixture.EctoUserSchema] do
        which = :code.which(mod)

        assert is_list(which),
               "module #{inspect(mod)} not loaded with a disk-resident .beam after setup_all; " <>
                 ":code.which/1 returned #{inspect(which)}"
      end

      module = LaneFixture.EctoUser
      pre_md5 = apply(module, :__info__, [:md5])
      pre_attrs = attribute_signature(module)

      json =
        run_pipeline!([
          "--scope",
          "LaneFixture.EctoUser",
          "--tests",
          "test/lane_fixture/ecto_user_test.exs",
          "--timeout-ms",
          "2000"
        ])

      assert json["aborted"] == false,
             "expected non-aborted run for ecto_user.ex; got JSON=#{inspect(json, limit: :infinity)}"

      post_md5 = apply(module, :__info__, [:md5])

      assert post_md5 == pre_md5,
             "module MD5 changed after mutation pipeline — restore is not bytecode-identical.\n" <>
               "pre:  #{Base.encode16(pre_md5)}\npost: #{Base.encode16(post_md5)}"

      post_attrs = attribute_signature(module)
      assert post_attrs == pre_attrs

      assert apply(module, :__schema_kind__, []) == :registered
      assert apply(module, :name, []) == :string
      assert apply(module, :age, []) == :integer

      assert_lane_tree_unmodified!(ctx.pre_hashes)
    end
  end

  describe "Scenario 8 (solo): MacroHolder state_drift_warning" do
    @tag :macro_holder_scenario
    test "macro_holder.ex emits a state_drift_warning entry", _ctx do
      json =
        run_pipeline!([
          "--scope",
          "lib/lane_fixture/macro_holder.ex",
          "--tests",
          "test/lane_fixture/macro_holder_test.exs",
          "--timeout-ms",
          "2000"
        ])

      assert json["aborted"] == false
      mutation = json["mutation"]

      drift = mutation["state_drift_warning"]
      assert is_map(drift)

      mentions_macro_holder =
        Enum.any?(Map.keys(drift), fn k -> to_string(k) =~ "MacroHolder" end)

      assert mentions_macro_holder,
             "expected state_drift_warning to mention LaneFixture.MacroHolder; got #{inspect(drift)}"

      assert_e2e_golden!("scenario_8_macro_holder", json)
    end
  end

  # ---------------------------------------------------------------------------
  # Pipeline driver + collaborators
  # ---------------------------------------------------------------------------

  defp run_pipeline!(argv) do
    this = self()
    ref = make_ref()

    # Per bw mutagen-wrd.33, dispatch values are plain module atoms
    # (not `{module, function}` tuples).
    dispatch = %{
      io: __MODULE__.CaptureIoCollaborator,
      # `mutagen-wrd.11` fixed `TestSelector.resolve/2` to emit `exclude:
      # []` for bare-file targets, so the e2e suite now consumes the
      # production resolver directly. The `tests_collaborator` fork was
      # retired in the same commit.
      tests: MutagenEx.TestSelector,
      # `mutagen-wrd.37` fixed `MutagenEx.Baseline.run/1` to re-register
      # each cited test module via `ExUnit.Server.add_module/2` before
      # its `ExUnit.run/0` (the cited modules are otherwise drained
      # from the registry by the prior coverage `ExUnit.run/0` and
      # `Code.require_file/1`'s cache makes the `__after_compile__`
      # hook a no-op on second contact). The e2e suite now consumes
      # the production `MutagenEx.Baseline` module directly; the
      # `BaselineCollaborator` fork was retired in the same commit.
      baseline: MutagenEx.Baseline,
      coverage: __MODULE__.CoverageCollaborator,
      # `mutagen-wrd.12` fixed `Mix.Tasks.Mutagen.phase_mutation/7` to
      # derive `test_modules` from the resolved `test_filter.files` via
      # `MutagenEx.TestModuleDiscovery.discover/1`, so the e2e suite now
      # consumes the production `MutationRunner.run/1` directly. The
      # `mutation_collaborator` fork (and its `discover_test_modules`
      # / `alias_to_module` helpers) was retired in the same commit.
      mutation: MutagenEx.MutationRunner
    }

    prior_cwd = File.cwd!()
    File.cd!(@lane_project_dir)

    try do
      Process.put(:e2e_capture_target, this)
      Process.put(:e2e_capture_ref, ref)

      _ =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          ExUnit.CaptureIO.capture_io(fn ->
            try do
              Mix.Tasks.Mutagen.run(argv, dispatch)
            rescue
              e ->
                send(this, {:e2e_raised, ref, Exception.message(e), __STACKTRACE__})
            catch
              kind, value ->
                send(this, {:e2e_caught, ref, kind, value})
            end
          end)
        end)

      receive do
        {:e2e_io, ^ref, iodata, _exit_code} ->
          decode_json!(iodata)

        {:e2e_raised, ^ref, message, _trace} ->
          flunk("pipeline raised: " <> message)

        {:e2e_caught, ^ref, kind, value} ->
          flunk("pipeline caught: #{inspect(kind)} #{inspect(value)}")
      after
        300_000 ->
          flunk("pipeline did not emit JSON within 300s")
      end
    after
      File.cd!(prior_cwd)
      Process.delete(:e2e_capture_target)
      Process.delete(:e2e_capture_ref)
    end
  end

  # Per bw mutagen-wrd.33, dispatch collaborators are modules, not
  # `{module, function}` tuples. The three stubs below implement the
  # relevant pipeline facades; each delegates to the original
  # collaborator body (left as plain functions in case other test
  # files want to call them directly).

  defmodule CaptureIoCollaborator do
    @moduledoc false
    @behaviour MutagenEx.Pipeline.IoFacade

    @impl MutagenEx.Pipeline.IoFacade
    def emit(iodata, exit_code, _config) do
      case Process.get(:e2e_capture_target) do
        target when is_pid(target) ->
          ref = Process.get(:e2e_capture_ref)
          send(target, {:e2e_io, ref, iodata, exit_code})
          :ok

        _ ->
          IO.write(iodata)
      end
    end
  end

  defmodule CoverageCollaborator do
    @moduledoc false
    # `Code.require_file/1` is one-shot per path — the second call on
    # the same file is cached and the `use ExUnit.Case`
    # `__after_compile__` hook does not re-fire, so the cited test
    # module is not re-registered with `ExUnit.Server` on the second
    # `ExUnit.run/0` in the same BEAM (a hazard internal to ExUnit's
    # registry-consumed-per-run semantics). For scenarios that cite the
    # same test file across two scenarios in this suite (e.g.
    # Scenarios 3c + 3d both cite `withblock_test.exs`), the second
    # scenario's coverage phase would otherwise run zero tests and
    # produce empty coverage data. This collaborator prepends a
    # `Code.compile_file/1` to re-evaluate the cited file so the
    # `__after_compile__` hook re-fires.
    #
    # Production `MutagenEx.Baseline` solved its half of this hazard
    # in mutagen-wrd.37 via explicit `ExUnit.Server.add_module/2`
    # (see `BaselineFacade`); the symmetric fix for
    # `MutagenEx.CoverageRunner` is tracked separately because it
    # touches `lib/mutagen_ex/coverage_runner.ex`, which falls
    # outside mutagen-wrd.37's allowed scope.
    @behaviour MutagenEx.Pipeline.CoverageFacade

    @impl MutagenEx.Pipeline.CoverageFacade
    def run(input) do
      MutagenEx.EndToEndTest.register_test_modules_for_phase!(input.test_filter.files)
      MutagenEx.CoverageRunner.run(input)
    end
  end

  # Compile every cited test file via `Code.compile_file/1`, which
  # unconditionally re-evaluates the source (unlike `Code.require_file/1`
  # which caches by path). The re-evaluation fires the `use ExUnit.Case`
  # `__after_compile__` hook, which itself calls `ExUnit.Server.add_module`
  # — so each scenario gets its cited test modules freshly registered
  # without us needing a parallel explicit add_module call (doing both
  # would register the module twice and make the cited tests run twice).
  #
  # Rationale for compile_file vs require_file: `Code.require_file/1` is
  # one-shot per path. Across scenarios the second citation of the same
  # file becomes a no-op and the `__after_compile__` hook does NOT
  # re-fire, leaving the cited test module unregistered for the second
  # scenario's `ExUnit.run/0`. `Code.compile_file/1` sidesteps the cache
  # at the cost of one "warning: redefining module" message per cited
  # file per scenario; the e2e driver swallows stderr in `run_pipeline!/1`.
  @doc false
  def register_test_modules_for_phase!(files) do
    Enum.each(files, fn file ->
      try do
        _ = Code.compile_file(file)
      rescue
        _ -> :ok
      catch
        _, _ -> :ok
      end
    end)

    :ok
  end

  # ---------------------------------------------------------------------------
  # JSON decoding + helpers
  # ---------------------------------------------------------------------------

  defp decode_json!(iodata) do
    binary = IO.iodata_to_binary(iodata)

    # mutagen.json_schema.r8: trailing newline.
    assert String.ends_with?(binary, "\n"),
           "json output must terminate with exactly one trailing newline"

    case :json.decode(binary) do
      decoded when is_map(decoded) ->
        # :json.decode/1 represents JSON null as the atom :null.
        # Convert to nil recursively for Elixir-conventional matches.
        json_null_to_nil(decoded)

      other ->
        flunk("decoded JSON is not a map: #{inspect(other)}")
    end
  end

  defp json_null_to_nil(:null), do: nil

  defp json_null_to_nil(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {k, json_null_to_nil(v)} end)
  end

  defp json_null_to_nil(list) when is_list(list) do
    Enum.map(list, &json_null_to_nil/1)
  end

  defp json_null_to_nil(other), do: other

  defp assert_lane_tree_unmodified!(pre_hashes) do
    for {f, pre_hash} <- pre_hashes do
      path = Path.join(@lane_lib_dir, f)
      post_hash = :crypto.hash(:sha256, File.read!(path))

      assert post_hash == pre_hash,
             "lane fixture source #{f} modified during pipeline run — " <>
               "mutagen.mutation_pipeline.r11 violated"
    end
  end

  defp ensure_cover_loadable! do
    case Code.ensure_loaded(:cover) do
      {:module, :cover} ->
        :ok

      _ ->
        root = List.to_string(:code.root_dir())

        case Path.wildcard(Path.join(root, "lib/tools-*/ebin")) do
          [path | _] ->
            Code.append_path(path)
            {:module, :cover} = Code.ensure_loaded(:cover)
            :ok

          [] ->
            flunk("could not locate OTP tools-*/ebin under #{root}")
        end
    end
  end

  # Compile each lane fixture .ex file into `ebin`. Returns the list of
  # compiled module atoms and a map of pre-pipeline MD5 fingerprints.
  #
  # `:cover.compile_beam/1` requires the module to have a real `.beam`
  # path discoverable via `:code.which/1`. In-memory modules return
  # `:in_memory` and cover refuses them, so we:
  #
  # 1. `Code.compile_file/1` to get {mod, bytecode} pairs;
  # 2. write each `.beam` to `ebin`;
  # 3. `:code.purge/1` + `:code.load_file/1` to reload each module from
  #    disk, making `:code.which/1` return the disk path.
  defp compile_lane_fixture(ebin) do
    compiled =
      Enum.flat_map(@lane_fixture_files, fn f ->
        path = Path.join(@lane_lib_dir, f)
        Code.compile_file(path)
      end)

    for {mod, bin} <- compiled do
      File.write!(Path.join(ebin, "#{mod}.beam"), bin)
    end

    for {mod, _bin} <- compiled do
      :code.purge(mod)
      :code.delete(mod)

      case :code.load_file(mod) do
        {:module, ^mod} ->
          :ok

        other ->
          flunk("could not reload #{inspect(mod)} from disk: #{inspect(other)}")
      end
    end

    modules = Enum.map(compiled, fn {mod, _bin} -> mod end)

    pre_md5 =
      for mod <- modules, into: %{} do
        {mod, mod.__info__(:md5)}
      end

    {modules, pre_md5}
  end

  # Captures persisted attributes of a compiled module, excluding the
  # compiler-stamped `:vsn` tag (which legitimately changes per
  # recompile).
  defp attribute_signature(mod) do
    apply(mod, :__info__, [:attributes])
    |> Enum.reject(fn {k, _v} -> k == :vsn end)
    |> Enum.sort()
  end

  # ---------------------------------------------------------------------------
  # Golden-fixture compare (per-scenario)
  # ---------------------------------------------------------------------------

  @golden_dir Path.join([__DIR__, "golden"])

  # Normalise environment- and run-dependent fields out of the decoded
  # JSON so the byte-equal compare against the per-scenario golden is
  # stable across hosts and ExUnit seeds. See the module doc's
  # "Golden-fixture compare" section for the exact rules.
  defp normalize_for_golden(value), do: do_normalize(value, [])

  defp do_normalize(value, path) when is_map(value) do
    Map.new(value, fn {k, v} ->
      new_path = [k | path]

      case normalize_field(new_path, v) do
        {:replace, replacement} -> {k, replacement}
        :recurse -> {k, do_normalize(v, new_path)}
      end
    end)
  end

  defp do_normalize(list, _path) when is_list(list) do
    Enum.map(list, fn item -> do_normalize(item, []) end)
  end

  defp do_normalize(other, _path), do: other

  # Path-aware normalisation rules. Returns either `{:replace, value}`
  # to substitute a stable placeholder or `:recurse` to keep walking.
  # Paths are leaf-first (head is the deepest key).
  defp normalize_field(["elixir_version", "meta"], _v), do: {:replace, "<NORMALIZED>"}
  defp normalize_field(["otp_version", "meta"], _v), do: {:replace, "<NORMALIZED>"}
  defp normalize_field(["tool_version", "meta"], _v), do: {:replace, "<NORMALIZED>"}

  # `mutation.results[].warnings` contain absolute-path text in the
  # cover-recompile warning (`current version loaded from /var/folders/…`).
  # Replace the warning list with its length so the shape is asserted
  # without bit-level drift.
  defp normalize_field(["warnings" | _rest], v) when is_list(v) do
    {:replace, %{"count" => length(v)}}
  end

  # `coverage.covered_lines.<file>` is encoded as a packed binary
  # bitmap that JSON encodes as a charlist (or string of characters).
  # The shape is byte-stable per source but the byte content is more
  # detail than a structural compare wants to pin. Replace each value
  # with its byte length.
  defp normalize_field(["covered_lines", "coverage"], v) when is_map(v) do
    {:replace, Map.new(v, fn {file, bitmap} -> {file, bitmap_size_label(bitmap)} end)}
  end

  defp normalize_field(_path, _v), do: :recurse

  defp bitmap_size_label(bitmap) when is_binary(bitmap), do: %{"bytes" => byte_size(bitmap)}
  defp bitmap_size_label(bitmap) when is_list(bitmap), do: %{"bytes" => length(bitmap)}
  defp bitmap_size_label(other), do: other

  # Compare the captured JSON (after normalisation) against the
  # per-scenario golden file. The compare is byte-equal on the
  # encoded JSON of the normalised structure. Mirrors the
  # `MutagenEx.JsonReporterGoldenTest` regen-with-env-var convention:
  # set `REGEN=1` to rewrite each golden file from the current output.
  defp assert_e2e_golden!(scenario_name, decoded_json) do
    normalised = normalize_for_golden(decoded_json)
    fixture = Path.join(@golden_dir, "end_to_end_#{scenario_name}.json")
    actual = encode_canonical_json(normalised)

    if System.get_env("REGEN") == "1" do
      File.mkdir_p!(@golden_dir)
      File.write!(fixture, actual)
      :ok
    else
      case File.read(fixture) do
        {:ok, expected} ->
          if expected != actual do
            actual_path = fixture <> ".actual"
            File.write!(actual_path, actual)

            flunk(
              "golden drift in #{Path.relative_to_cwd(fixture)}.\n" <>
                "Wrote actual output to #{Path.relative_to_cwd(actual_path)}.\n" <>
                "Diff: diff #{Path.relative_to_cwd(fixture)} #{Path.relative_to_cwd(actual_path)}.\n" <>
                "If this drift is intentional, regenerate with: " <>
                "REGEN=1 mix test test/mutagen_ex/end_to_end_test.exs --only e2e_slow"
            )
          end

          :ok

        {:error, :enoent} ->
          flunk(
            "missing e2e golden fixture #{Path.relative_to_cwd(fixture)}. " <>
              "Generate with: REGEN=1 mix test test/mutagen_ex/end_to_end_test.exs --only e2e_slow"
          )
      end
    end
  end

  # Encode the normalised structure with deterministic key ordering so
  # the byte-equal compare is stable. The Elixir/OTP `:json` encoder
  # does not guarantee map key order; we sort here for determinism. We
  # also convert `nil` → `:null` because `:json.encode/1` stringifies
  # the Elixir atom `nil` as the literal string `"nil"` (it only
  # recognises `:null` as JSON null).
  defp encode_canonical_json(value) do
    iodata = :json.encode(sort_keys(value))
    IO.iodata_to_binary(iodata) <> "\n"
  end

  defp sort_keys(map) when is_map(map) do
    map
    |> Enum.sort_by(fn {k, _} -> to_string(k) end)
    |> Enum.map(fn {k, v} -> {to_string(k), sort_keys(v)} end)
    |> :maps.from_list()
  end

  defp sort_keys(list) when is_list(list), do: Enum.map(list, &sort_keys/1)
  defp sort_keys(nil), do: :null
  defp sort_keys(other), do: other
end
