defmodule MutagenEx.Integration.ArchiveInstallTest do
  @moduledoc """
  Archive-install integration test for `mix mutagen`.

  Builds this project as a Mix archive, installs it into a per-run
  `MIX_ARCHIVES` directory, then drives `mix mutagen` from a fresh host
  project that does not declare `:mutagen_ex` as a dependency. This gates the
  archive-context runtime repair path in `mutagen.cli.r16`.
  """

  use ExUnit.Case, async: false

  @moduletag :archive_integration

  @project_root Path.expand("../..", __DIR__)

  test "fresh-shell `mix mutagen` succeeds when mutagen_ex is installed as an archive" do
    version = MutagenEx.MixProject.project()[:version]
    archive_filename = "mutagen_ex-#{version}.ez"
    archive_path = Path.join(@project_root, archive_filename)

    rand = :rand.uniform(1_000_000_000) |> Integer.to_string()
    app_name = "mutagen_ex_archive_test_#{rand}"
    tmp_dir = Path.join(System.tmp_dir!(), app_name)
    scratch_dir = Path.join(System.tmp_dir!(), "mutagen_ex_archives_test_#{rand}")

    File.rm_rf!(tmp_dir)
    File.rm_rf!(scratch_dir)
    File.rm_rf!(archive_path)
    File.mkdir_p!(scratch_dir)

    on_exit(fn ->
      File.rm_rf!(scratch_dir)
      File.rm_rf!(tmp_dir)
      File.rm_rf!(archive_path)
    end)

    Mix.Task.reenable("archive.build")
    Mix.Task.run("archive.build")

    assert File.exists?(archive_path),
           "expected `Mix.Task.run(\"archive.build\")` to create #{archive_path}"

    {install_out, install_code} =
      System.cmd("mix", ["archive.install", "--force", archive_path],
        cd: System.tmp_dir!(),
        stderr_to_stdout: true,
        env: scoped_env(scratch_dir)
      )

    assert install_code == 0,
           "`mix archive.install` failed (exit #{install_code}):\n#{install_out}"

    {new_out, new_code} =
      System.cmd("mix", ["new", "--sup", app_name],
        cd: System.tmp_dir!(),
        stderr_to_stdout: true,
        env: clean_env(scratch_dir)
      )

    assert new_code == 0,
           "`mix new #{app_name}` failed (exit #{new_code}):\n#{new_out}"

    assert File.dir?(tmp_dir),
           "expected `mix new` to create #{tmp_dir}, but it does not exist"

    app_module = Macro.camelize(app_name) <> ".Application"
    agent_name = Macro.camelize(app_name) <> ".Store"
    app_dir = String.replace(app_name, ~r/_(\d)/, "\\1")
    app_path = Path.join([tmp_dir, "lib", app_dir, "application.ex"])

    File.write!(app_path, """
    defmodule #{app_module} do
      @moduledoc false
      use Application

      @impl Application
      def start(_type, _args) do
        children = [
          %{id: #{agent_name}, start: {Agent, :start_link, [fn -> 41 end, [name: #{agent_name}]]}}
        ]

        Supervisor.start_link(children, strategy: :one_for_one, name: #{app_module}.Supervisor)
      end
    end
    """)

    calc_module = Macro.camelize(app_name) <> ".Calc"
    calc_path = Path.join([tmp_dir, "lib", app_name, "calc.ex"])
    File.mkdir_p!(Path.dirname(calc_path))

    File.write!(calc_path, """
    defmodule #{calc_module} do
      @moduledoc false

      def add(a, b), do: a + b
      def stored, do: Agent.get(#{agent_name}, & &1)
    end
    """)

    calc_test_path = Path.join([tmp_dir, "test", app_name, "calc_test.exs"])
    File.mkdir_p!(Path.dirname(calc_test_path))

    File.write!(calc_test_path, """
    defmodule #{calc_module}Test do
      use ExUnit.Case, async: true

      test "add/2 sums two integers" do
        assert #{calc_module}.add(1, 2) == 3
      end

      test "add/2 is commutative for integers" do
        assert #{calc_module}.add(2, 3) == #{calc_module}.add(3, 2)
      end

      test "stored/0 reads the host OTP supervision tree" do
        assert #{calc_module}.stored() == 41
      end
    end
    """)

    relative_scope = Path.join(["lib", app_name, "calc.ex"])
    relative_tests = Path.join(["test", app_name, "calc_test.exs"])

    {mutagen_out, mutagen_code} =
      System.cmd(
        "mix",
        ["mutagen", "--scope", relative_scope, "--tests", relative_tests],
        cd: tmp_dir,
        stderr_to_stdout: false,
        env: scoped_env(scratch_dir)
      )

    assert mutagen_code == 0,
           """
           `mix mutagen` exited #{mutagen_code} in the archive-installed host project.
           stdout:
           #{mutagen_out}
           """

    json_line = extract_json_document(mutagen_out)

    decoded =
      try do
        :json.decode(json_line)
      rescue
        e ->
          flunk("""
          extracted JSON line did not decode: #{Exception.message(e)}

          --- extracted line ---
          #{json_line}

          --- raw stdout ---
          #{mutagen_out}
          """)
      end

    assert is_map(decoded),
           "expected JSON object at top level, got: #{inspect(decoded)}"

    assert decoded["aborted"] == false,
           "expected aborted: false, got: #{inspect(decoded["aborted"])}\n" <>
             "full document: #{inspect(decoded, pretty: true, limit: :infinity)}"

    assert decoded["abort_reason"] in [nil, :null],
           "expected abort_reason JSON null, got: #{inspect(decoded["abort_reason"])}\n" <>
             "full document: #{inspect(decoded, pretty: true, limit: :infinity)}"

    mutation = decoded["mutation"]

    assert is_map(mutation),
           "expected `mutation` block to be a map, got: #{inspect(mutation)}"

    total = mutation["total"]

    assert is_integer(total) and total > 0,
           "expected mutation.total > 0, got: #{inspect(total)}\n" <>
             "full document: #{inspect(decoded, pretty: true, limit: :infinity)}"

    assert mutation["completed"] > 0,
           "expected at least one mutation to have executed, not just been enumerated"
  end

  defp clean_env(scratch_dir) do
    [
      {"MIX_ENV", nil},
      {"MIX_TARGET", nil},
      {"MIX_ARCHIVES", scratch_dir}
    ]
  end

  defp scoped_env(scratch_dir), do: clean_env(scratch_dir)

  defp extract_json_document(stdout) do
    stdout
    |> String.split("\n", trim: true)
    |> Enum.reverse()
    |> Enum.find(fn line ->
      trimmed = String.trim(line)

      String.starts_with?(trimmed, "{") and String.ends_with?(trimmed, "}") and
        json_parses?(trimmed)
    end)
    |> case do
      nil ->
        flunk("""
        no JSON document found in `mix mutagen` stdout.

        --- raw stdout ---
        #{stdout}
        """)

      line ->
        String.trim(line)
    end
  end

  defp json_parses?(line) do
    _ = :json.decode(line)
    true
  rescue
    _ -> false
  end
end
