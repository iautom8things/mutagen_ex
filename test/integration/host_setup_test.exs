defmodule MutagenEx.Integration.HostSetupTest do
  use ExUnit.Case, async: false

  @moduletag :host_setup_integration
  @moduletag timeout: to_timeout(minute: 3)

  @project_root Path.expand("../..", __DIR__)
  @fixture Path.join(@project_root, "test/fixtures/host_setup_project")
  @scope "lib/host_setup_fixture/orders.ex"
  @tests "checks/orders_test.exs"

  test "path dependency runs the host helper and sandbox tests across mutation cycles" do
    host = prepare_host(mutagen_path: @project_root)

    assert_host_run(host)
  end

  test "installed archive runs the same host setup with a partitioned database" do
    host = prepare_host(partition: "2")
    archive = Path.join(host.dir, "mutagen_ex.ez")

    Mix.Task.reenable("archive.build")
    Mix.Task.run("archive.build", ["-o", archive])
    mix!(host, ["archive.install", "--force", archive])

    assert_host_run(host)
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

  defp assert_host_run(host) do
    {stdout, status} = mix(host, ["mutagen", "--scope", @scope, "--tests", @tests])
    assert status == 0, "mix mutagen exited #{status}\n#{stdout}"

    report = :json.decode(stdout)
    assert %{"aborted" => false, "baseline" => %{"passed" => 1, "failed" => 0}} = report

    results = report["mutation"]["results"]
    assert Enum.any?(results, &(&1["status"] == "killed"))
    assert Enum.any?(results, &(&1["status"] == "survived"))

    assert File.read!(Path.join(host.dir, "runs.log")) ==
             "helper\n" <> String.duplicate("order\n", 2 + length(results))
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
