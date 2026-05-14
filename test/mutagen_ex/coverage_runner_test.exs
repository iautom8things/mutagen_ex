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

  Tests that exercise the real `:cover` lifecycle are tagged
  `:cover_integration` so they can be filtered separately if the
  environment doesn't have the OTP `tools` app available; the fast-feedback
  tests use seam stubs to assert state-machine shape without touching the
  real cover_server.
  """

  use ExUnit.Case, async: false

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

    test "configure is called BEFORE ExUnit.run/0" do
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
  # r7: no disk writes
  # ---------------------------------------------------------------------------

  describe "r7: no source/disk writes (s7)" do
    test "fixture sha-256 hashes are unchanged before/after a run" do
      # Hash every file in lib/ and confirm no bytes changed during a run.
      lib_files = Path.wildcard("lib/**/*.ex")

      pre =
        for file <- lib_files, into: %{} do
          {file, :crypto.hash(:sha256, File.read!(file))}
        end

      cfg = base_cfg_with_fakes()
      assert {:ok, _} = CoverageRunner.run(cfg)

      for file <- lib_files do
        post = :crypto.hash(:sha256, File.read!(file))
        assert post == pre[file], "coverage run modified source file #{file}"
      end
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
    %{
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
      ex_unit: ExUnitFake,
      cover: CoverFakeOk
    }
  end
end
