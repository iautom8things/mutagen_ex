defmodule MutagenEx.Pipeline.DefaultIoTest do
  use ExUnit.Case, async: true

  alias MutagenEx.Config
  alias MutagenEx.Pipeline.DefaultIo

  @tag :tmp_dir
  @tag spec: ["mutagen.cli.r5", "mutagen.cli.r23"]
  test "routes one newline-terminated JSON document to the configured destination", %{
    tmp_dir: dir
  } do
    document = ~s({"aborted":false}\n)
    emit = &DefaultIo.emit/3
    config = %Config{scopes: [], tests: []}

    assert {^document, 0} = run_sink(emit, document, config)

    file = Path.join(dir, "report.json")
    assert {"", 0} = run_sink(emit, document, %{config | json_path: file})
    assert File.read!(file) == document
    assert Bitwise.band(File.stat!(file).mode, 0o777) == 0o600
  end

  # The sink calls System.halt/1. Run it in an isolated VM so a regression
  # cannot halt ExUnit before it reports the result.
  defp run_sink(emit, document, config) do
    args = inspect([document, 0, config])

    System.cmd("elixir", [
      "-pa",
      Mix.Project.compile_path(),
      "-e",
      "apply(#{inspect(emit)}, #{args})"
    ])
  end
end
