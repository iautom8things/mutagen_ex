defmodule MutagenEx.CoverageRunnerTest do
  @moduledoc """
  Tests for `MutagenEx.CoverageRunner`.

  Subjects advanced (see `.spec/specs/coverage.spec.md`):

    * `mutagen.coverage.r1` / `s1` — refuses to run if `:cover_server` is
      already registered.
    * `mutagen.coverage.r2` / `s2` — calls `:cover.stop/0` on every exit
      path. Idempotent under repeated stops.
    * `mutagen.coverage.r3` / `s3` — `:code.which/1` is non-`:cover_compiled`
      after `run/1` returns.
    * `mutagen.coverage.r4` / `s4` — forces `ExUnit.configure(max_cases: 1,
      seed: cfg.seed)` before ExUnit begins running.
    * `mutagen.coverage.r5` / `s5` — `covered_lines` keys only include files
      in `cfg.in_scope_modules`.
    * `mutagen.coverage.r7` / `s7` — no disk writes during the run.
      Asserted across `lib/`, `_build/`, `cover/`, host project config
      (mix.exs, mix.lock, .formatter.exs), and tmp entries with the
      `mutagen_ex_` prefix — see the r7 describe block below.

  Tests that exercise the real `:cover` lifecycle are tagged
  `:cover_integration` so they can be filtered separately if the
  environment doesn't have the OTP `tools` app available; the fast-feedback
  tests use seam stubs to assert state-machine shape without touching the
  real cover_server.
  """

  # Load the disk-snapshot test helper for the r7 broader surface check.
  # See note in mutation_runner_test.exs for why we require_file rather
  # than route through mix.exs `elixirc_paths`.
  Code.require_file("../support/disk_snapshot_helper.exs", __DIR__)

  use ExUnit.Case, async: false

  # Every test here drives `CoverageRunner.run/1` (the documented
  # `:cover_server` singleton owner) or otherwise manipulates the real
  # `:cover` lifecycle, so the whole module is cover-hostile. Under
  # `mix test --cover` the harness owns `:cover_server`; test_helper.exs
  # excludes this tag in that mode. See test_helper.exs for the rationale.
  @moduletag :cover_lifecycle

  alias MutagenEx.CoverageRunner
  alias MutagenEx.TestSelector.TestFilter

  # ---- defensive cleanup per H-Tt3 -------------------------------------------
  setup do
    on_exit(fn ->
      # `:cover` may not be loaded at this point — use `apply/3` so the
      # compiler doesn't warn on the static reference.
      try do
        apply(:cover, :stop, [])
      rescue
        _ -> :ok
      catch
        _, _ -> :ok
      end
    end)

    :ok
  end

  # ---- Fakes ----------------------------------------------------------------

  defmodule ExUnitFake do
    @moduledoc false
    def configure(opts) do
      Process.put(:exunit_fake_configure, opts)
      :ok
    end

    def run do
      Process.put(:exunit_fake_run_called, (Process.get(:exunit_fake_run_called) || 0) + 1)
      %{failures: 0, total: 0, excluded: 0, skipped: 0}
    end
  end

  defmodule ExUnitFakeFailing do
    @moduledoc false
    def configure(_opts), do: :ok
    def run, do: raise("boom from fake ExUnit.run/0")
  end

  defmodule CoverFakeOk do
    @moduledoc false
    def start do
      Process.put(:cover_fake_started, true)
      {:ok, self()}
    end

    def stop do
      Process.put(:cover_fake_stopped, (Process.get(:cover_fake_stopped) || 0) + 1)
      :ok
    end

    def compile_beam(_path) do
      target = Process.get(:cover_fake_compile_target, :ok)

      case target do
        :ok -> {:ok, Process.get(:cover_fake_module, FakeModule)}
        other -> other
      end
    end

    def analyse(_module, :coverage, :line) do
      {:ok, Process.get(:cover_fake_analyse, [])}
    end
  end

  # ---------------------------------------------------------------------------
  # r1: cover already running
  # ---------------------------------------------------------------------------

  describe "r1: refuses if :cover_server already registered (s1)" do
    test "returns :cover_already_running and does NOT call configure/run/compile" do
      # Register a placeholder under :cover_server so the runner sees a
      # live registration. The runner must NOT touch it.
      {:ok, sentinel} = Agent.start_link(fn -> :i_am_someone_elses_cover end)
      Process.register(sentinel, :cover_server)

      cfg = %{
        seed: 42,
        in_scope_modules: [{__MODULE__, "test/mutagen_ex/coverage_runner_test.exs"}],
        test_filter: %TestFilter{include: [], exclude: [:test], files: []},
        ex_unit: ExUnitFake,
        cover: CoverFakeOk
      }

      assert {:error, :cover_already_running, details} = CoverageRunner.run(cfg)
      assert is_binary(details.message)
      # r1 (revised): the rejection message names MutagenEx.TaskSup as the
      # documented singleton owner — see .spec/decisions/supervision_tree.md.
      assert details.message =~ "MutagenEx.TaskSup"

      # Neither configure/0 nor run/0 were called.
      assert Process.get(:exunit_fake_configure) == nil
      assert Process.get(:exunit_fake_run_called) == nil
      # cover.start was NOT called either.
      assert Process.get(:cover_fake_started) == nil

      # The original :cover_server registration is still ours, untouched.
      assert Process.whereis(:cover_server) == sentinel
      assert Agent.get(sentinel, & &1) == :i_am_someone_elses_cover

      Process.unregister(:cover_server)
      Agent.stop(sentinel)
    end
  end

  # ---------------------------------------------------------------------------
  # r2: cover.stop called on every exit (success, error, raise)
  # ---------------------------------------------------------------------------

  describe "r2: :cover.stop/0 called on every exit (s2 — idempotent)" do
    test "successful run calls cover.stop at least once" do
      cfg = base_cfg_with_fakes()

      assert {:ok, _result} = CoverageRunner.run(cfg)
      assert (Process.get(:cover_fake_stopped) || 0) >= 1
    end

    test "ExUnit.run/0 raising still calls cover.stop" do
      cfg =
        base_cfg_with_fakes()
        |> Map.put(:ex_unit, ExUnitFakeFailing)

      assert {:error, :ex_unit_run_failed, _} = CoverageRunner.run(cfg)
      assert (Process.get(:cover_fake_stopped) || 0) >= 1
    end

    test "cover.stop is idempotent under multiple consecutive runs" do
      cfg = base_cfg_with_fakes()

      assert {:ok, _} = CoverageRunner.run(cfg)
      first = Process.get(:cover_fake_stopped) || 0

      Process.delete(:cover_fake_stopped)

      # Second run in the same VM must succeed — stop didn't leave cover
      # in a broken state. s2 invariant.
      assert {:ok, _} = CoverageRunner.run(cfg)
      second = Process.get(:cover_fake_stopped) || 0

      assert first >= 1
      assert second >= 1
    end
  end

  # ---------------------------------------------------------------------------
  # r4: forced ExUnit configuration
  # ---------------------------------------------------------------------------

  describe "r4: forces ExUnit max_cases: 1 + seed (s4)" do
    test "configure/1 receives max_cases: 1 and the configured seed" do
      cfg = base_cfg_with_fakes(seed: 1234)

      assert {:ok, _result} = CoverageRunner.run(cfg)

      opts = Process.get(:exunit_fake_configure)
      assert is_list(opts)
      assert Keyword.get(opts, :max_cases) == 1
      assert Keyword.get(opts, :seed) == 1234
    end

    test "configure and run are both invoked" do
      # The fake records both calls; on a successful run, configure must
      # have happened first OR concurrently — but since the runner is
      # single-process, "before" is enforced by the call order in
      # do_run/1.
      cfg = base_cfg_with_fakes()
      assert {:ok, _} = CoverageRunner.run(cfg)
      assert Process.get(:exunit_fake_configure) != nil
      assert (Process.get(:exunit_fake_run_called) || 0) == 1
    end

    test "include/exclude from TestFilter is propagated" do
      cfg =
        base_cfg_with_fakes(
          test_filter: %TestFilter{
            include: [:integration],
            exclude: [:test, :slow],
            files: []
          }
        )

      assert {:ok, _} = CoverageRunner.run(cfg)

      opts = Process.get(:exunit_fake_configure)
      assert Keyword.get(opts, :include) == [:integration]
      assert Keyword.get(opts, :exclude) == [:test, :slow]
    end
  end

  # ---------------------------------------------------------------------------
  # r5: scope filter — covered_lines keys are subset of in_scope_modules' files
  # ---------------------------------------------------------------------------

  describe "r5: covered_lines is filtered to in-scope files (s5)" do
    @tag :scope_filter
    test "out-of-scope coverage entries are dropped" do
      # Pretend the user scoped to `lib/foo.ex` (one module: Foo).
      # `:cover.analyse` will surface lines for Foo (in scope) AND, in a
      # separate `gather_covered_lines` iteration, lines that would belong
      # to a different file. The runner walks `in_scope_modules`, so the
      # only way an out-of-scope file appears in the result is via a
      # `cover.analyse` return that names a wrong file — but the runner
      # uses the {module, file} tuple from cfg, so the only path to
      # out-of-scope leakage is mis-iterating. We assert by adding a
      # module whose analyse result is non-empty, and confirming the
      # result map only has keys we declared in_scope.
      Process.put(:cover_fake_module, MutagenEx.CoverageRunnerTest)

      Process.put(:cover_fake_analyse, [
        {{MutagenEx.CoverageRunnerTest, 1}, {3, 0}},
        {{MutagenEx.CoverageRunnerTest, 5}, {2, 0}},
        {{MutagenEx.CoverageRunnerTest, 10}, {0, 1}}
      ])

      cfg =
        base_cfg_with_fakes(
          in_scope_modules: [
            {MutagenEx.CoverageRunnerTest, "test/mutagen_ex/coverage_runner_test.exs"}
          ]
        )

      assert {:ok, %{covered_lines: covered}} = CoverageRunner.run(cfg)

      assert Map.keys(covered) == ["test/mutagen_ex/coverage_runner_test.exs"]

      assert MapSet.equal?(
               covered["test/mutagen_ex/coverage_runner_test.exs"],
               MapSet.new([1, 5])
             )
    end

    @tag :scope_filter
    test "lines with zero coverage are excluded from the MapSet" do
      Process.put(:cover_fake_module, MutagenEx.CoverageRunnerTest)

      Process.put(:cover_fake_analyse, [
        {{MutagenEx.CoverageRunnerTest, 42}, {0, 0}},
        {{MutagenEx.CoverageRunnerTest, 99}, {7, 0}}
      ])

      cfg =
        base_cfg_with_fakes(
          in_scope_modules: [
            {MutagenEx.CoverageRunnerTest, "test/mutagen_ex/coverage_runner_test.exs"}
          ]
        )

      assert {:ok, %{covered_lines: covered}} = CoverageRunner.run(cfg)
      assert MapSet.equal?(covered["test/mutagen_ex/coverage_runner_test.exs"], MapSet.new([99]))
    end
  end

  # ---------------------------------------------------------------------------
  # r7: no disk writes (broader surface)
  # ---------------------------------------------------------------------------
  #
  # The r7 invariant ("Neither CoverageRunner.run/1 nor AstCache.load/1
  # modifies any file on disk") is broader than `lib/**/*.ex`. The
  # original test hashed only the source surface and would ship green
  # if `CoverageRunner` accidentally:
  #
  #   * Wrote a coverage report under `cover/`
  #   * Touched `_build/**/*.beam` (e.g. by leaving cover-compiled
  #     artifacts on disk instead of in-memory)
  #   * Rewrote `mix.exs` / `mix.lock` / `.formatter.exs`
  #   * Stashed instrumented state under `/tmp` without cleanup
  #
  # This broader test asserts byte-identity across the same surface as
  # the r11 test in mutation_runner_test.exs (see that file for the
  # full allowed-write rationale). The stubbed CoverageRunner pass
  # here has no allowed-write surface: every diff category must be
  # empty.
  #
  # Real-cover behavior (cover-instrumented .beam files DO modify
  # process state but must NOT land on disk) is covered indirectly by
  # the `:cover_integration` test below and exhaustively by C1
  # (test/mutagen_ex/integration/c1_test.exs), which already snapshots
  # its own fixture sources.

  describe "r7: no disk writes (broader surface, s7)" do
    test "lib/, _build/, cover/, host config, and /tmp are byte-identical before/after a coverage run" do
      pre = MutagenEx.TestSupport.DiskSnapshot.snapshot()

      cfg = base_cfg_with_fakes()
      assert {:ok, _} = CoverageRunner.run(cfg)

      post = MutagenEx.TestSupport.DiskSnapshot.snapshot()
      diff = MutagenEx.TestSupport.DiskSnapshot.diff(pre, post)

      # Modified files: any content change to a snapshotted path is
      # a violation. The stubbed coverage run does not modify disk.
      assert diff.modified == [],
             "r7 regression: coverage run modified files on disk:\n" <>
               Enum.map_join(diff.modified, "\n  ", &("- " <> &1))

      # Removed files: the runner must never delete user content.
      assert diff.removed == [],
             "r7 regression: coverage run removed files from disk:\n" <>
               Enum.map_join(diff.removed, "\n  ", &("- " <> &1))

      # Added files: the runner must not create coverage reports, beam
      # artifacts, or any other disk artifact under the snapshotted
      # globs.
      assert diff.added == [],
             "r7 regression: coverage run created files on disk:\n" <>
               Enum.map_join(diff.added, "\n  ", &("- " <> &1))

      # /tmp entries with `mutagen_ex_` prefix: only flag MutagenEx-
      # attributable entries to avoid flake from concurrent test
      # processes.
      attributable = MutagenEx.TestSupport.DiskSnapshot.mutagen_attributable_tmp(diff)

      assert attributable == [],
             "r7 regression: coverage run created tmp entries with `mutagen_ex_` prefix:\n" <>
               Enum.map_join(attributable, "\n  ", &("- " <> &1))
    end
  end

  # ---------------------------------------------------------------------------
  # r3 — verified end-to-end against real :cover via the C1 spike. Repeating
  # the full cover-instrument/restore loop here would re-execute C1's slow
  # 100-iter behaviour. We satisfy r3 here with a single real-cover
  # instrumentation against one of our own modules and assert the
  # post-`stop` :code.which/1 result.
  # ---------------------------------------------------------------------------

  describe "r3: :code.which/1 is non-:cover_compiled after stop (s3) — real cover" do
    @tag :cover_integration
    test "post-run :code.which/1 returns a real .beam path for instrumented modules" do
      # Use our own AstCache module (loaded and present on disk). The
      # runner instruments it via :cover.compile_beam, runs no actual
      # tests (we use the fake ExUnit so we don't fork a real test
      # session here), then stops cover. After that, :code.which must
      # return the original .beam path.
      file_path = "lib/mutagen_ex/ast_cache.ex"

      pre_which = :code.which(MutagenEx.AstCache)
      assert is_list(pre_which), "AstCache must be loaded for this test to run"

      cfg = %{
        seed: 0,
        in_scope_modules: [{MutagenEx.AstCache, file_path}],
        test_filter: %TestFilter{include: [], exclude: [:test], files: []},
        ex_unit: ExUnitFake
      }

      assert {:ok, _} = CoverageRunner.run(cfg)

      post_which = :code.which(MutagenEx.AstCache)
      refute post_which == :cover_compiled
      assert is_list(post_which) or post_which == :preloaded
    end
  end

  # ---------------------------------------------------------------------------
  # Error-shape sanity
  # ---------------------------------------------------------------------------

  # ---------------------------------------------------------------------------
  # mutagen-wrd.38: cited-module re-registration seam
  # ---------------------------------------------------------------------------

  defmodule ExUnitServerFake do
    @moduledoc false
    def add_module(module, cfg) do
      list = Process.get(:ex_unit_server_fake_calls, [])
      Process.put(:ex_unit_server_fake_calls, [{module, cfg} | list])
      :ok
    end
  end

  defmodule OrderingExUnitServer do
    @moduledoc false
    # Records `add_module/2` calls into the shared `:wrd38_order`
    # process-dict list so the ordering test can assert `add_module`
    # ran before `ExUnit.run/0`.
    def add_module(module, _cfg) do
      list = Process.get(:wrd38_order, [])
      Process.put(:wrd38_order, [{:add_module, module} | list])
      :ok
    end
  end

  defmodule OrderingExUnit do
    @moduledoc false
    def configure(_opts), do: :ok

    def run do
      list = Process.get(:wrd38_order, [])
      Process.put(:wrd38_order, [:run | list])
      %{failures: 0, total: 0, excluded: 0, skipped: 0}
    end
  end

  describe "mutagen-wrd.38: re-registers cited test modules before ExUnit.run/0" do
    setup do
      Process.delete(:ex_unit_server_fake_calls)
      Process.delete(:wrd38_order)
      :ok
    end

    test ":test_modules entries are passed to :ex_unit_server.add_module/2 in order" do
      mod_cfg = %{async?: false, group: nil, parameterize: nil}

      cfg =
        base_cfg_with_fakes(
          test_modules: [
            {Some.Cited.ATest, mod_cfg},
            {Some.Cited.BTest, mod_cfg}
          ],
          ex_unit_server: ExUnitServerFake
        )

      assert {:ok, _} = CoverageRunner.run(cfg)

      calls = Process.get(:ex_unit_server_fake_calls) |> Enum.reverse()

      assert calls == [
               {Some.Cited.ATest, mod_cfg},
               {Some.Cited.BTest, mod_cfg}
             ]
    end

    test "add_module/2 happens BEFORE ExUnit.run/0" do
      mod_cfg = %{async?: false, group: nil, parameterize: nil}

      cfg =
        base_cfg_with_fakes(
          test_modules: [{Some.Cited.OrderingTest, mod_cfg}],
          ex_unit_server: OrderingExUnitServer,
          ex_unit: OrderingExUnit
        )

      assert {:ok, _} = CoverageRunner.run(cfg)

      order = Process.get(:wrd38_order) |> Enum.reverse()

      assert order == [
               {:add_module, Some.Cited.OrderingTest},
               :run
             ]
    end

    test "default for :test_modules is [] — no add_module calls when payload absent" do
      cfg =
        base_cfg_with_fakes(ex_unit_server: ExUnitServerFake)
        |> Map.delete(:test_modules)

      assert {:ok, _} = CoverageRunner.run(cfg)
      assert Process.get(:ex_unit_server_fake_calls) == nil
    end

    test "empty :test_modules with default :ex_unit_server does not crash" do
      # No `:ex_unit_server` override and an empty `:test_modules` list.
      # The default seam must not be exercised (`Enum.each` over `[]` is
      # a no-op) — this asserts the default lookup path doesn't crash
      # when the real `MutagenEx.Test.ExUnitServer` is the seam value.
      cfg = base_cfg_with_fakes() |> Map.put(:test_modules, [])
      assert {:ok, _} = CoverageRunner.run(cfg)
    end
  end

  describe "input validation" do
    test "rejects malformed inputs with :invalid_input" do
      assert {:error, :invalid_input, _} = CoverageRunner.run(%{})

      assert {:error, :invalid_input, _} =
               CoverageRunner.run(%{
                 seed: -1,
                 in_scope_modules: [],
                 test_filter: %TestFilter{include: [], exclude: [:test], files: []}
               })

      assert {:error, :invalid_input, _} =
               CoverageRunner.run(%{
                 seed: 0,
                 in_scope_modules: [{"not_an_atom", "file.ex"}],
                 test_filter: %TestFilter{include: [], exclude: [:test], files: []}
               })
    end
  end

  # ---- helpers ----

  defp base_cfg_with_fakes(overrides \\ []) do
    base = %{
      seed: Keyword.get(overrides, :seed, 0),
      in_scope_modules:
        Keyword.get(overrides, :in_scope_modules, [
          {MutagenEx.CoverageRunnerTest, "test/mutagen_ex/coverage_runner_test.exs"}
        ]),
      test_filter:
        Keyword.get(overrides, :test_filter, %TestFilter{
          include: [],
          exclude: [:test],
          files: []
        }),
      ex_unit: Keyword.get(overrides, :ex_unit, ExUnitFake),
      cover: Keyword.get(overrides, :cover, CoverFakeOk)
    }

    # Optional keys: only set when the test specifies them so default
    # behaviour matches production lookup paths.
    Enum.reduce([:test_modules, :ex_unit_server], base, fn key, acc ->
      case Keyword.fetch(overrides, key) do
        {:ok, value} -> Map.put(acc, key, value)
        :error -> acc
      end
    end)
  end
end
