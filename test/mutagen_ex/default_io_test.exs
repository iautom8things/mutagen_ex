defmodule MutagenEx.DefaultIoTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  @moduletag spec: "mutagen.cli.r23"
  alias MutagenEx.{Config, JsonPath}
  alias MutagenEx.Pipeline.DefaultIo

  @tag spec: "mutagen.json_schema.r39"
  test "writes one report to stdout with one fixed notice on stderr" do
    document = "{\"aborted\":false}\n"

    {stdout, stderr} =
      with_io(:stderr, fn ->
        capture_io(fn -> DefaultIo.write(document, %Config{scopes: [], tests: []}) end)
      end)

    assert stdout == document
    assert JSON.decode!(stdout) == %{"aborted" => false}
    assert stderr == "Use --json PATH for reliable reports in scripts and CI.\n"
  end

  @tag :tmp_dir
  test "creates an in-project report directory and atomically replaces the report", %{
    tmp_dir: dir
  } do
    config = report_config(dir, "new/nested/report.json")
    assert :ok = DefaultIo.write("first\n", config)
    assert :ok = DefaultIo.write("second\n", config)
    assert File.read!(config.json_path) == "second\n"
    assert File.ls!(Path.dirname(config.json_path)) == ["report.json"]
  end

  @tag :tmp_dir
  test "falls back to stdout when the destination is a directory", %{tmp_dir: dir} do
    File.mkdir!(Path.join(dir, "report.json"))
    config = report_config(dir, "report.json")
    assert_fallback(config)
    assert File.dir?(config.json_path)
  end

  @tag :tmp_dir
  test "rejects a symlink planted after initial validation", %{tmp_dir: dir} do
    project = Path.join(dir, "project")
    outside = Path.join(dir, "outside")
    File.mkdir!(project)
    File.mkdir!(outside)
    config = report_config(project, "out/report.json")

    File.ln_s!(outside, Path.join(project, "out"))
    assert_fallback(config)
    assert File.ls!(outside) == []
  end

  defp assert_fallback(config) do
    {stdout, stderr} =
      with_io(:stderr, fn ->
        capture_io(fn -> DefaultIo.write("{\"aborted\":true}\n", config) end)
      end)

    assert stdout == "{\"aborted\":true}\n"
    assert stderr =~ "json_write_failed"
  end

  defp report_config(root, path) do
    {:ok, canonical} = JsonPath.canonicalize(path, project_root: root)
    %Config{scopes: [], tests: [], json_root: root, json_path: canonical, json_requested: path}
  end
end
