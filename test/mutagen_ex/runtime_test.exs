defmodule MutagenEx.RuntimeTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO
  alias MutagenEx.Runtime

  setup_all do
    # run/1 loads the report modules before boot. Boot's loadpaths prunes
    # this project's ebin from the fixture's code path.
    Code.ensure_loaded!(MutagenEx.JsonReporter.Sanitizer)
    :ok
  end

  @tag :tmp_dir
  @tag spec: ["mutagen.cli.r14", "mutagen.cli.r18"]
  test "uses no default helper when test/ is absent and honors explicit MIX_ENV", %{tmp_dir: dir} do
    in_project(dir, fn ->
      previous_env = Mix.env()
      previous_explicit = System.get_env("MIX_ENV")

      try do
        Mix.env(:ci)
        System.put_env("MIX_ENV", "ci")
        assert {:ok, %{test_paths: []}} = Runtime.boot(host_app: false)
        System.delete_env("MIX_ENV")

        assert {:error, :invalid_mix_env, %{message: message}} =
                 Runtime.boot(
                   command: "MIX_ENV=test mix mutagen --scope lib/a.ex --tests test/a_test.exs"
                 )

        assert message =~ "MIX_ENV=test mix mutagen --scope lib/a.ex --tests test/a_test.exs"
        assert message =~ "preferred_envs: [mutagen: :test]"
      after
        Mix.env(previous_env)

        if previous_explicit,
          do: System.put_env("MIX_ENV", previous_explicit),
          else: System.delete_env("MIX_ENV")
      end
    end)
  end

  @tag :tmp_dir
  @tag spec: "mutagen.cli.r19"
  test "refuses umbrella roots with the child command location", %{tmp_dir: dir} do
    in_project(
      dir,
      fn ->
        assert {:error, :umbrella_root, %{message: message}} = Runtime.boot()
        assert message =~ "apps/<app>"
      end,
      "apps_path: \"apps\""
    )
  end

  @tag :tmp_dir
  @tag spec: "mutagen.cli.r21"
  test "uses its own deadline for a hanging helper", %{tmp_dir: dir} do
    write_helper(dir, "File.write!(\"helper-entered\", \"yes\"); Process.sleep(:infinity)")

    in_project(dir, fn ->
      started = System.monotonic_time(:millisecond)

      assert {:error, :host_setup_timeout, %{step: :test_helper_load_failed}} =
               Runtime.boot(host_app: false, boot_timeout_ms: 1_000)

      assert File.read!("helper-entered") == "yes"
      assert System.monotonic_time(:millisecond) - started < to_timeout(second: 5)
    end)
  end

  @tag :tmp_dir
  @tag spec: "mutagen.cli.r19"
  test "reports a linked helper exit instead of exiting the calling process", %{tmp_dir: dir} do
    write_helper(
      dir,
      "spawn_link(fn -> exit(:fixture_linked_exit) end); Process.sleep(:infinity)"
    )

    in_project(dir, fn ->
      capture_io(:stderr, fn ->
        assert {:error, :test_helper_load_failed, %{message: message}} =
                 Runtime.boot(host_app: false)

        assert message =~ "fixture_linked_exit"
      end)
    end)
  end

  @tag :tmp_dir
  @tag spec: "mutagen.cli.r19"
  test "locates a helper failure in the helper and names the evaluated file it came from", %{
    tmp_dir: dir
  } do
    File.mkdir_p!(Path.join(dir, "priv"))

    File.write!(Path.join(dir, "priv/seeds.exs"), """
    # Seeds for the fixture.
    #
    #
    #
    #
    raise "seed insert failed"
    """)

    write_helper(dir, """
    # The helper's first lines are comments,
    # so line 6 of this file is not code.
    #
    #
    #
    #
    #
    ExUnit.configure(exclude: [:slow])
    Code.eval_file("priv/seeds.exs")
    """)

    in_project(dir, fn ->
      capture_io(:stderr, fn ->
        assert {:error, :test_helper_load_failed, details} = Runtime.boot(host_app: false)

        assert %{
                 file: "test/test_helper.exs",
                 line: 9,
                 origin_file: "priv/seeds.exs",
                 origin_line: 6
               } = details
      end)
    end)
  end

  @tag :tmp_dir
  @tag spec: "mutagen.cli.r19"
  test "reports no origin for a failure raised in the helper itself", %{tmp_dir: dir} do
    write_helper(dir, "# comment\nraise \"helper failed\"\n")

    in_project(dir, fn ->
      capture_io(:stderr, fn ->
        assert {:error, :test_helper_load_failed, details} = Runtime.boot(host_app: false)
        assert %{file: "test/test_helper.exs", line: 2} = details
        refute Map.has_key?(details, :origin_file)
      end)
    end)
  end

  @tag :tmp_dir
  @tag spec: "mutagen.cli.r22"
  test "reports an alias pre-step failure and allows opting out", %{tmp_dir: dir} do
    in_project(
      dir,
      fn ->
        capture_io(:stderr, fn ->
          assert {:error, :test_alias_failed, %{message: message}} = Runtime.boot(host_app: false)
          assert message =~ "alias failed"
        end)

        assert {:ok, _} = Runtime.boot(host_app: false, test_alias: false)
      end,
      ~s(aliases: [test: [fn [] -> raise "alias failed" end, "test"]])
    )
  end

  @tag :tmp_dir
  @tag spec: "mutagen.cli.r19"
  test "compiler MatchError details omit an unlabelled term", %{tmp_dir: dir} do
    File.mkdir!(Path.join(dir, "lib"))

    File.write!(Path.join(dir, "lib/failing.ex"), """
    defmodule RuntimeFixture.CompilerFailure do
      @token "fixture-unlabelled-token"
      :ok = {:error, @token}
    end
    """)

    in_project(dir, fn ->
      capture_io(:stderr, fn ->
        assert {:error, :host_compile_failed, %{message: message}} = Runtime.boot()
        assert message =~ "no match of right hand side value"
        assert message =~ "[REDACTED]"
        refute message =~ "fixture-unlabelled-token"
      end)
    end)
  end

  @tag spec: "mutagen.cli.r20"
  test "captured callbacks run once in ExUnit order and failures do not skip later callbacks" do
    previous = Application.fetch_env!(:ex_unit, :after_suite)
    caller = self()

    try do
      ExUnit.configure(after_suite: [])
      ExUnit.after_suite(fn stats -> send(caller, {:first, stats}) end)
      ExUnit.after_suite(fn _ -> throw(:fixture_cleanup) end)
      callbacks = Runtime.take_after_suite()

      assert Runtime.take_after_suite() == []
      stats = %{total: 2, failures: 0, excluded: 1, skipped: 0}

      capture_io(:stderr, fn ->
        assert {:error, :after_suite_failed, _} =
                 Runtime.finish(%{worker: nil, callbacks: callbacks}, stats)
      end)

      assert_received {:first, ^stats}
      refute_received {:first, _}
    after
      ExUnit.configure(after_suite: previous)
    end
  end

  defp write_helper(dir, body) do
    File.mkdir_p!(Path.join(dir, "test"))
    File.write!(Path.join(dir, "test/test_helper.exs"), body)
  end

  defp in_project(dir, fun, opts \\ "deps: []") do
    id = System.unique_integer([:positive])

    File.write!(Path.join(dir, "mix.exs"), """
    defmodule RuntimeFixture.Project#{id} do
      use Mix.Project
      def project, do: [app: :mutagen_runtime_fixture, version: "0.0.0", #{opts}]
    end
    """)

    code_path = :code.get_path()

    try do
      Mix.Project.in_project(:"mutagen_runtime_fixture_#{id}", dir, fn _ -> fun.() end)
    after
      :code.set_path(code_path)
    end
  end
end
