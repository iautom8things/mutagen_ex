defmodule MutagenEx.Integration.HostSetupTest do
  use ExUnit.Case, async: false

  @moduletag :host_setup_integration
  @moduletag timeout: to_timeout(minute: 3)

  @project_root Path.expand("../..", __DIR__)
  @fixture Path.join(@project_root, "test/fixtures/host_setup_project")
  @scope "lib/host_setup_fixture/orders.ex"
  @tests "checks/orders_test.exs"

  setup_all do
    dependency = prepare_host(mutagen_path: @project_root)
    archive = prepare_host(partition: "2")
    archive_path = Path.join(archive.dir, "mutagen_ex.ez")

    Mix.Task.reenable("archive.build")
    Mix.Task.run("archive.build", ["-o", archive_path])
    mix!(archive, ["archive.install", "--force", archive_path])

    {:ok, dependency: dependency, archive: archive}
  end

  describe "path dependency" do
    test "runs the host helper and sandbox tests across mutation cycles", %{dependency: host} do
      assert_host_run(host)
    end

    test "refuses the dev environment with an actionable JSON error", %{dependency: host} do
      host = put_env(host, "MIX_ENV", "dev")
      mix!(host, ["deps.loadpaths"])

      assert abort(host, "invalid_mix_env") =~ "requires MIX_ENV=test"
    end
  end

  describe "installed archive" do
    test "runs the same host setup with a partitioned database", %{archive: host} do
      assert_host_run(host)
    end

    test "an explicit line selection narrows the helper's includes", %{archive: host} do
      helper_path = "checks/test_helper.exs"
      helper = File.read!(Path.join(host.dir, helper_path))

      line =
        host.dir
        |> Path.join(@tests)
        |> File.stream!()
        |> Enum.find_index(&String.contains?(&1, ~s(test "prices an order)))

      with_file(host, helper_path, helper <> "\nExUnit.configure(include: [:load])\n", fn ->
        assert_host_run(host, "#{@tests}:#{line + 1}")
      end)
    end

    test "refuses the default dev environment before attempting host startup", %{archive: host} do
      host = put_env(host, "MIX_ENV", nil)
      assert abort(host, "invalid_mix_env") =~ "current Mix environment: dev"
    end

    test "reports an unreachable database to the requested JSON file", %{archive: host} do
      {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
      {:ok, port} = :inet.port(socket)
      :ok = :gen_tcp.close(socket)

      host =
        host
        |> put_env("HOST_SETUP_DB_HOST", "127.0.0.1")
        |> put_env("HOST_SETUP_DB_PORT", Integer.to_string(port))

      started = System.monotonic_time(:millisecond)
      {stdout, status} = mutate(host, ["--json", "host-error.json"])

      assert System.monotonic_time(:millisecond) - started < to_timeout(second: 10)
      assert status != 0
      assert stdout == ""
      report = File.read!(Path.join(host.dir, "host-error.json"))
      assert abort_message(report, "host_app_start_failed") =~ "Could not start application"
    end

    test "reports a host loadpaths failure", %{archive: host} do
      mixfile = File.read!(Path.join(host.dir, "mix.exs"))

      with_file(
        host,
        "mix.exs",
        String.replace(mixfile, "deps: deps()", """
        deps: [{:missing_host_dep, path: "missing"} | deps()]
        """),
        fn ->
          assert abort(host, "host_loadpaths_failed") =~ "errors on dependencies"
        end
      )
    end

    test "reports a host compiler error", %{archive: host} do
      with_file(host, @scope, "defmodule HostSetupFixture.Orders do", fn ->
        assert abort(host, "host_compile_failed") =~ "missing terminator"
      end)
    end

    test "reports a missing helper", %{archive: host} do
      with_file(host, "checks/test_helper.exs", nil, fn ->
        assert abort(host, "test_helper_load_failed", ["--stream"]) =~ "checks/test_helper.exs"
      end)
    end

    test "reports a raising helper with sanitized details", %{archive: host} do
      with_file(
        host,
        "checks/test_helper.exs",
        """
        Application.put_env(:mutagen_ex, :redact, ["FIXTURE_SECRET"])
        raise "helper did not start: FIXTURE_SECRET"
        """,
        fn ->
          assert abort(host, "test_helper_load_failed") == "helper did not start: [REDACTED]"
        end
      )
    end

    test "skipping the host app still loads the helper", %{archive: host} do
      with_file(
        host,
        "checks/test_helper.exs",
        """
        if Process.whereis(HostSetupFixture.Repo), do: raise("unexpected running repo")
        raise "helper ran without the repo"
        """,
        fn ->
          assert abort(host, "test_helper_load_failed", ["--no-host-app"]) ==
                   "helper ran without the repo"

          assert abort(put_env(host, "MUTAGEN_NO_HOST_APP", "1"), "test_helper_load_failed") ==
                   "helper ran without the repo"
        end
      )
    end
  end

  defp prepare_host(opts) do
    suffix = Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
    dir = Path.join(@project_root, "tmp/host_setup_#{suffix}")
    database = System.get_env("HOST_SETUP_DB_NAME", "mutagen_host_setup") <> "_" <> suffix <> "_"
    File.mkdir_p!(Path.dirname(dir))
    File.cp_r!(@fixture, dir)

    host = %{
      dir: dir,
      env: [
        {"MIX_ENV", "test"},
        {"MIX_TARGET", nil},
        {"MIX_QUIET", if(opts[:mutagen_path], do: "1")},
        {"MIX_ARCHIVES", Path.join(dir, "archives")},
        {"MIX_TEST_PARTITION", opts[:partition]},
        {"HOST_SETUP_MUTAGEN_PATH", opts[:mutagen_path]},
        {"HOST_SETUP_DB_NAME", database},
        {"MUTAGEN_NO_HOST_APP", nil}
      ]
    }

    on_exit(fn -> File.rm_rf!(dir) end)
    mix!(host, ["deps.get"])

    on_exit(fn -> mix!(host, ["ecto.drop", "--quiet"]) end)

    mix!(host, ["ecto.create", "--quiet"])
    mix!(host, ["ecto.migrate", "--quiet"])
    host
  end

  defp assert_host_run(host, tests \\ @tests) do
    trace = Path.join(host.dir, "runs.log")
    File.write!(trace, "")
    {stdout, status} = mutate(host, [], tests)
    assert status == 0, "mix mutagen exited #{status}\n#{stdout}"

    report = decode_report(stdout)
    assert %{"aborted" => false, "baseline" => %{"passed" => 1, "failed" => 0}} = report

    results = report["mutation"]["results"]
    assert %{"killed" => 3, "survived" => 1, "total" => 4} = report["mutation"]
    assert Enum.any?(results, &match?(%{"before" => "total + 2", "status" => "killed"}, &1))
    assert Enum.any?(results, &match?(%{"mutator" => "else_removal", "status" => "survived"}, &1))

    assert File.read!(trace) == "helper\n" <> String.duplicate("order\n", 2 + length(results))
  end

  defp mutate(host, args, tests \\ @tests) do
    mix(host, ["mutagen", "--scope", @scope, "--tests", tests] ++ args)
  end

  defp abort(host, reason, args \\ []) do
    {stdout, status} = mutate(host, args)
    assert status != 0
    abort_message(stdout, reason)
  end

  defp abort_message(json, reason) do
    assert %{
             "aborted" => true,
             "abort_reason" => ^reason,
             "details" => %{"message" => message},
             "baseline" => :null,
             "mutation" => :null
           } = decode_report(json)

    message
  end

  defp decode_report(stdout) do
    :json.decode(stdout)
  rescue
    _ -> flunk("expected one JSON document, got:\n#{stdout}")
  end

  defp put_env(host, name, value) do
    %{host | env: List.keystore(host.env, name, 0, {name, value})}
  end

  defp with_file(host, file, replacement, fun) do
    path = Path.join(host.dir, file)
    original = File.read!(path)

    try do
      if replacement, do: File.write!(path, replacement), else: File.rm!(path)
      fun.()
    after
      File.write!(path, original)
    end
  end

  defp mix!(host, args) do
    {output, status} = mix(host, args, stderr_to_stdout: true)
    assert status == 0, "mix #{Enum.join(args, " ")} exited #{status}\n#{output}"
    output
  end

  defp mix(host, args, opts \\ []) do
    System.cmd("mix", args, [cd: host.dir, env: host.env] ++ opts)
  end
end
