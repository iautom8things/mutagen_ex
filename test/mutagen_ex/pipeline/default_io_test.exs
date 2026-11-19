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

  @tag spec: "mutagen.cli.r30"
  test "the VM user proxy sends reads and geometry to the original device" do
    owner = self()

    user =
      spawn(fn ->
        for {operation, answer} <- [
              {{:get_line, :unicode, ""}, "fixture\n"},
              {{:get_geometry, :columns}, 80}
            ] do
          receive do
            {:io_request, from, ref, ^operation} ->
              send(owner, operation)
              send(from, {:io_reply, ref, answer})
          end
        end
      end)

    {:ok, stderr} = StringIO.open("")
    proxy = DefaultIo.route_device(user, stderr)
    assert IO.gets(proxy, "prompt> ") == "fixture\n"
    assert :io.columns(proxy) == {:ok, 80}
    IO.write(proxy, "example")
    assert StringIO.contents(stderr) == {"", "prompt> example"}
    send(proxy, :stop)
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
