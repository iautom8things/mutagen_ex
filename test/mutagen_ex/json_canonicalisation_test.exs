defmodule MutagenEx.JsonCanonicalisationTest do
  @moduledoc """
  Integration tests for the `phase_json_path` hook in `Mix.Tasks.Mutagen`.

  Coverage of `mutagen.cli.r10` scenarios that need real filesystem state:

    * `mutagen.cli.s10c` — symlink whose target escapes the project root
      aborts BEFORE any mutation phase runs (no /etc write)
    * `mutagen.cli.s10d` — symlink whose target stays inside the project
      root resolves and the canonical path lands on `Config.json_path`
    * `mutagen.cli.s10e` — `--unsafe-json-outside-project` bypasses the
      inside-root check and writes a one-shot stderr warning naming the
      resolved path

  These tests cannot use `File.cd!/2` because ExUnit's parallel test
  loader reads `File.cwd!/0` to require_file other test modules — a
  cd-during-test races with that. Instead the production code reads its
  project root override from the calling process's dictionary
  (`Process.put(:mutagen_json_path_project_root, ...)`), which is
  test-process-local and safe.

  The tests still run `async: true` because the process-dictionary
  override is per-test-process.
  """

  use ExUnit.Case, async: true

  Code.require_file("../support/path_helpers.exs", __DIR__)

  alias MutagenEx.Config

  setup do
    Process.put(:capture_target, self())
    :ok
  end

  describe "phase_json_path — symlink escape (s10c)" do
    test "symlink whose target escapes the project root aborts before any mutation phase" do
      tmp = isolated_project_root()
      escape = Path.join(tmp, "escape.json")
      File.ln_s!("/etc/hosts", escape)

      Process.put(:mutagen_json_path_project_root, tmp)

      dispatch = capture_full_dispatch(scope: &fail_scope/2)

      assert {:aborted, :unsafe_json_path, _report} =
               Mix.Tasks.Mutagen.run(
                 [
                   "--scope",
                   "lib/foo.ex",
                   "--tests",
                   "test/foo_test.exs",
                   "--json",
                   "escape.json"
                 ],
                 dispatch
               )

      assert_received {:io, iodata, code, _config}
      assert code != 0

      decoded =
        iodata
        |> IO.iodata_to_binary()
        |> :json.decode()

      assert decoded["abort_reason"] == "unsafe_json_path"

      # The scope collaborator was never called — the abort happened in
      # the canonicalisation phase, BEFORE scope resolution. The fake
      # scope (which would record a message) is silent here.
      refute_received {:scope_invoked, _}
    end

    test "intermediate symlinked parent that escapes the root also aborts" do
      tmp = isolated_project_root()
      escape_parent = Path.join(tmp, "data")
      File.ln_s!("/tmp", escape_parent)

      Process.put(:mutagen_json_path_project_root, tmp)
      dispatch = capture_full_dispatch(scope: &fail_scope/2)

      assert {:aborted, :unsafe_json_path, _report} =
               Mix.Tasks.Mutagen.run(
                 [
                   "--scope",
                   "lib/foo.ex",
                   "--tests",
                   "test/foo_test.exs",
                   "--json",
                   "data/report.json"
                 ],
                 dispatch
               )

      assert_received {:io, iodata, code, _config}
      assert code != 0

      decoded =
        iodata
        |> IO.iodata_to_binary()
        |> :json.decode()

      assert decoded["abort_reason"] == "unsafe_json_path"
    end
  end

  describe "phase_json_path — symlink stays inside root (s10d)" do
    test "symlink resolution succeeds; canonical path lands on Config" do
      tmp = isolated_project_root()
      File.mkdir_p!(Path.join(tmp, "out"))
      target = Path.join(tmp, "out/report.json")
      link = Path.join(tmp, "inside.json")
      File.ln_s!(target, link)

      Process.put(:mutagen_json_path_project_root, tmp)
      dispatch = capture_full_dispatch(scope: &fail_scope/2)

      Mix.Tasks.Mutagen.run(
        [
          "--scope",
          "lib/foo.ex",
          "--tests",
          "test/foo_test.exs",
          "--json",
          "inside.json"
        ],
        dispatch
      )

      assert_received {:io, _iodata, _code, %Config{} = config}
      # The canonical path is the symlink target (in resolved form), not
      # the user-supplied "inside.json".
      expected = resolve_symlinks(target)
      assert config.json_path == expected
      assert config.unsafe_json_outside_project == false
    end

    test "literal-safe path in a non-existent subdirectory passes (final tail is allowed to not exist)" do
      tmp = isolated_project_root()
      Process.put(:mutagen_json_path_project_root, tmp)
      dispatch = capture_full_dispatch(scope: &fail_scope/2)

      Mix.Tasks.Mutagen.run(
        [
          "--scope",
          "lib/foo.ex",
          "--tests",
          "test/foo_test.exs",
          "--json",
          "newdir/report.json"
        ],
        dispatch
      )

      assert_received {:io, _iodata, _code, %Config{json_path: path}}
      expected = Path.join(resolve_symlinks(tmp), "newdir/report.json")
      assert path == expected
    end
  end

  describe "phase_json_path — outside-root default refusal" do
    test "absolute path outside project root aborts" do
      tmp = isolated_project_root()
      Process.put(:mutagen_json_path_project_root, tmp)
      dispatch = capture_full_dispatch(scope: &fail_scope/2)

      assert {:aborted, :unsafe_json_path, _report} =
               Mix.Tasks.Mutagen.run(
                 [
                   "--scope",
                   "lib/foo.ex",
                   "--tests",
                   "test/foo_test.exs",
                   "--json",
                   "/tmp/escape-#{System.unique_integer([:positive])}.json"
                 ],
                 dispatch
               )

      assert_received {:io, iodata, code, _config}
      assert code != 0

      decoded =
        iodata
        |> IO.iodata_to_binary()
        |> :json.decode()

      assert decoded["abort_reason"] == "unsafe_json_path"
    end
  end

  describe "phase_json_path — --unsafe-json-outside-project escape hatch (s10e)" do
    test "outside-root absolute path succeeds with the flag set" do
      tmp = isolated_project_root()
      Process.put(:mutagen_json_path_project_root, tmp)
      dispatch = capture_full_dispatch(scope: &fail_scope/2)

      outside =
        Path.join(System.tmp_dir!(), "mutagen-ci-#{System.unique_integer([:positive])}.json")

      stderr =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          Mix.Tasks.Mutagen.run(
            [
              "--scope",
              "lib/foo.ex",
              "--tests",
              "test/foo_test.exs",
              "--json",
              outside,
              "--unsafe-json-outside-project"
            ],
            dispatch
          )
        end)

      assert_received {:io, _iodata, _code, %Config{} = config}
      assert config.unsafe_json_outside_project == true
      assert config.json_path == resolve_symlinks(outside)

      # Falsifiability: removing the warning emission would break this
      # set of asserts. Each substring is load-bearing for the user-facing
      # contract that the operator sees WHY their report is going outside
      # the project root.
      assert stderr =~ "warning"
      assert stderr =~ "--unsafe-json-outside-project"
      assert stderr =~ config.json_path
    end

    test "without the flag, the same outside-root path is refused" do
      tmp = isolated_project_root()
      Process.put(:mutagen_json_path_project_root, tmp)
      dispatch = capture_full_dispatch(scope: &fail_scope/2)

      outside =
        Path.join(System.tmp_dir!(), "mutagen-ci-#{System.unique_integer([:positive])}.json")

      stderr =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          assert {:aborted, :unsafe_json_path, _report} =
                   Mix.Tasks.Mutagen.run(
                     [
                       "--scope",
                       "lib/foo.ex",
                       "--tests",
                       "test/foo_test.exs",
                       "--json",
                       outside
                     ],
                     dispatch
                   )
        end)

      # Without the flag, no warning lands on stderr — the warning is
      # ONLY emitted when the unsafe flag is set AND canonicalisation
      # succeeded. The refusal path does not warn (it aborts).
      refute stderr =~ "warning"
    end
  end

  describe "phase_json_path — no --json flag (control)" do
    test "no canonicalisation phase work happens when json_path is nil" do
      tmp = isolated_project_root()
      Process.put(:mutagen_json_path_project_root, tmp)
      dispatch = capture_full_dispatch(scope: &fail_scope/2)

      Mix.Tasks.Mutagen.run(
        ["--scope", "lib/foo.ex", "--tests", "test/foo_test.exs"],
        dispatch
      )

      assert_received {:io, _iodata, _code, %Config{} = config}
      assert config.json_path == nil
      assert config.unsafe_json_outside_project == false
    end
  end

  # --- helpers ----------------------------------------------------------------
  #
  # Per bw mutagen-wrd.33, the Mix task dispatches via plain module
  # atoms — tests swap modules, not `{module, function}` tuples. The
  # phase stubs read their per-test bodies from the process dictionary
  # so individual tests can swap closures without minting new modules.

  defmodule PhaseStubs.Scope do
    @moduledoc false
    @behaviour MutagenEx.Pipeline.ScopeFacade

    @impl MutagenEx.Pipeline.ScopeFacade
    def resolve(target, opts) do
      apply(Process.get({:phase_fun, :scope}), [target, opts])
    end
  end

  defmodule PhaseStubs.Io do
    @moduledoc false
    @behaviour MutagenEx.Pipeline.IoFacade

    @impl MutagenEx.Pipeline.IoFacade
    def emit(iodata, code, config) do
      send(Process.get(:capture_target), {:io, iodata, code, config})
      :ok
    end
  end

  defp capture_full_dispatch(overrides) do
    scope_fun = Keyword.get(overrides, :scope, &fail_scope/2)
    Process.put({:phase_fun, :scope}, scope_fun)

    %{
      scope: PhaseStubs.Scope,
      io: PhaseStubs.Io
    }
  end

  defp fail_scope(target, _opts) do
    {:error, :module_not_found, %{target: target, message: "fake-scope refusal (test harness)"}}
  end

  defp isolated_project_root do
    base = Path.expand(System.tmp_dir!())
    suffix = "mutagen_canon_#{:erlang.unique_integer([:positive])}"
    path = Path.join(base, suffix)
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end

  defp resolve_symlinks(path), do: MutagenEx.Test.PathHelpers.resolve_symlinks(path)
end
