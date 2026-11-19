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
      Asserted across `lib/`, `_build/`, `cover/`, and host project config
      (mix.exs, mix.lock, .formatter.exs). r7's tmp-scratch clause is NOT
      asserted from this stubbed fixture — the runner does no filesystem
      I/O, so the check would be vacuous, and snapshotting the shared
      global `System.tmp_dir!()` flaked on ambient `mutagen_ex_*` churn
      (mutagen-de1; see the r7 describe block below). The tmp clause is
      guaranteed structurally and exercised via the real `:cover` lifecycle
      (the `:cover_integration` test + C1 spike, coverage verification v4).

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
    def run do
      Process.put(:exunit_fake_options, Application.get_all_env(:ex_unit))
      Process.put(:exunit_fake_run_called, (Process.get(:exunit_fake_run_called) || 0) + 1)

      Process.get(:coverage_fake_suite, fn ->
        %{failures: 0, total: 1, excluded: 0, skipped: 0}
      end).()
    end
  end

  defmodule ExUnitFakeFailing do
    @moduledoc false
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
    @tag spec: "mutagen.coverage.r1"
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
      assert Process.get(:exunit_fake_options) == nil
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

  @tag spec: "mutagen.coverage.r1"
  test "the empty cover server started by a helper can be replaced" do
    tools = Path.wildcard(Path.join([to_string(:code.root_dir()), "lib", "tools-*", "ebin"]))
    Enum.each(tools, &Code.append_path/1)
    assert {:ok, pid} = MutagenEx.Test.Cover.start()

    try do
      assert {:ok, _coverage} = CoverageRunner.run(base_cfg_with_fakes())
      refute Process.alive?(pid)
    after
      MutagenEx.Test.Cover.stop()
    end
  end

  @tag spec: "mutagen.coverage.r11"
  test "coverage catches ExUnit exits and throws and rejects a suite with no tests executed" do
    cfg = base_cfg_with_fakes()

    for {kind, fun} <- [exit: fn -> exit(:broken) end, throw: fn -> throw(:broken) end] do
      Process.put(:coverage_fake_suite, fun)
      assert {:error, :ex_unit_run_failed, %{message: message}} = CoverageRunner.run(cfg)
      assert message =~ "caught #{kind} during coverage"
    end

    Process.put(:coverage_fake_suite, fn -> %{total: 3, excluded: 3, skipped: 0, failures: 0} end)

    assert {:error, :no_tests_run, %{phase: :coverage, excluded: 3, include: [], exclude: []}} =
             CoverageRunner.run(%{
               cfg
               | test_filter: %TestFilter{files: [], include: [], exclude: []}
             })
  end

  # ---------------------------------------------------------------------------
  # r2: cover.stop called on every exit (success, error, raise)
  # ---------------------------------------------------------------------------

  describe "r2: :cover.stop/0 called on every exit (s2 — idempotent)" do
    @describetag spec: "mutagen.coverage.r2"

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
    @tag spec: ["mutagen.cli.r4", "mutagen.coverage.r4"]
    test "run/0 sees max_cases: 1 and the configured seed" do
      cfg = base_cfg_with_fakes(seed: 1234)

      assert {:ok, _result} = CoverageRunner.run(cfg)

      opts = Process.get(:exunit_fake_options)
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
      assert Process.get(:exunit_fake_options) != nil
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

      opts = Process.get(:exunit_fake_options)
      assert Keyword.get(opts, :include) == [:integration]
      assert Keyword.get(opts, :exclude) == [:test, :slow]
    end
  end

  # ---------------------------------------------------------------------------
  # r5: scope filter — covered_lines keys are subset of in_scope_modules' files
  # ---------------------------------------------------------------------------

  describe "r5: covered_lines is filtered to in-scope files (s5)" do
    @describetag spec: "mutagen.coverage.r5"

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
  # modifies any file on disk") is broader than `lib/**/*.ex`. This test
  # asserts byte-identity across the `lib/`, `_build/`, `cover/`, and
  # host-config surfaces for a stubbed CoverageRunner pass. Those surfaces
  # do not churn during ExUnit's serial sync phase (this module is
  # `async: false`, so no other test runs concurrently with it), so the
  # assertions are deterministic and would catch a stubbed-path write to
  # `cover/`, `_build/**/*.{beam,app}`, `lib/`, or host config.
  #
  describe "r7: no disk writes (broader surface, s7)" do
    test "lib/, _build/, cover/, and host config are byte-identical before/after a coverage run" do
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

      # NOTE: `diff.tmp_added` / `diff.tmp_removed` are intentionally NOT
      # asserted — see the describe-block comment above. They reflect the
      # shared global `System.tmp_dir!()`, which the stubbed runner cannot
      # touch and which ambient `mutagen_ex_*` churn makes non-deterministic
      # (mutagen-de1). r7's tmp clause is covered by the real-`:cover` paths.
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
    @tag spec: ["mutagen.coverage.r2", "mutagen.coverage.r3"]
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
      assert {:ok, _server} = MutagenEx.Test.Cover.start()
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
    def discard_pending_modules, do: :ok

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
    def discard_pending_modules, do: :ok

    def add_module(module, _cfg) do
      list = Process.get(:wrd38_order, [])
      Process.put(:wrd38_order, [{:add_module, module} | list])
      :ok
    end
  end

  defmodule OrderingExUnit do
    @moduledoc false

    def run do
      list = Process.get(:wrd38_order, [])
      Process.put(:wrd38_order, [:run | list])
      %{failures: 0, total: 1, excluded: 0, skipped: 0}
    end
  end

  describe "mutagen-wrd.38: re-registers cited test modules before ExUnit.run/0" do
    @describetag spec: "mutagen.coverage.r10"

    setup do
      Process.delete(:ex_unit_server_fake_calls)
      Process.delete(:wrd38_order)
      :ok
    end

    @tag spec: "mutagen.mutation_pipeline.r10"
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

      assert {:ok, %{test_modules: modules}} = CoverageRunner.run(cfg)
      assert modules == cfg.test_modules

      calls = Process.get(:ex_unit_server_fake_calls) |> Enum.reverse()

      assert calls == [
               {Some.Cited.ATest, mod_cfg},
               {Some.Cited.BTest, mod_cfg}
             ]
    end

    @tag spec: "mutagen.mutation_pipeline.r10"
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

    @tag spec: "mutagen.mutation_pipeline.r10"
    test "no add_module calls when neither a payload nor cited files are present" do
      cfg =
        base_cfg_with_fakes(ex_unit_server: ExUnitServerFake)
        |> Map.delete(:test_modules)

      assert {:ok, _} = CoverageRunner.run(cfg)
      assert Process.get(:ex_unit_server_fake_calls) == nil
    end

    @tag spec: "mutagen.mutation_pipeline.r25"
    test "reports a cited symlink whose path does not match the compiled case source" do
      dir =
        Path.join(System.tmp_dir!(), "mutagen_case_symlink_#{System.unique_integer([:positive])}")

      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      real = Path.join(dir, "real_test.exs")
      link = Path.join(dir, "alias_test.exs")

      File.write!(real, """
      defmodule SymlinkCase do
        def __ex_unit__, do: :sample
        def __ex_unit__(:config), do: %{async?: false, group: nil, parameterize: nil}
      end
      """)

      File.ln_s!(real, link)

      cfg =
        base_cfg_with_fakes()
        |> Map.put(:test_filter, %TestFilter{files: [link], include: [], exclude: []})
        |> Map.put(:test_loader, fn ^link -> Code.compile_file(real) end)

      assert {:error, :test_file_load_failed, %{file: ^link, message: message}} =
               CoverageRunner.run(cfg)

      assert message =~ "compiled source path"
      assert message =~ "real path instead of the symlink"
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
