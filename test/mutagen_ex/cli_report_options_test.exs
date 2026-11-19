defmodule MutagenEx.CliReportOptionsTest do
  use ExUnit.Case, async: true

  alias MutagenEx.JsonReporter
  alias MutagenEx.JsonReporter.Report

  @tag spec: "mutagen.cli.r31"
  test "an older OTP gets a startup error before argument parsing or host setup" do
    dispatch = %{otp_release: "26", io: __MODULE__.Capture, cli: nil}

    assert {:aborted, :unsupported_otp_version, _} = Mix.Tasks.Mutagen.run([], dispatch)
    assert_received {2, report, _config}

    assert %{
             "aborted" => true,
             "abort_reason" => "unsupported_otp_version",
             "details" => %{
               "actual" => "26",
               "hint" => "Run Mutagen with Erlang/OTP 27 or later."
             },
             "meta" => %{"otp_version" => "26", "max_concurrency" => 1}
           } = report
  end

  @tag spec: "mutagen.json_schema.r26"
  test "the dispatch limit is recorded and parallel runs warn even on early abort" do
    warning = "Verdicts are unreliable in experimental parallel mode."

    for {args, limit, warnings} <- [{[], 1, []}, {["--max-concurrency", "3"], 3, [warning]}] do
      assert {:aborted, :missing_scope, _} =
               Mix.Tasks.Mutagen.run(args, %{io: __MODULE__.Capture})

      assert_received {2, %{"meta" => %{"max_concurrency" => ^limit}, "warnings" => ^warnings}, _}

      assert {iodata, 0} = JsonReporter.emit_report(%Report{meta: %{max_concurrency: limit}})

      assert %{"meta" => %{"max_concurrency" => ^limit}, "warnings" => ^warnings} =
               iodata |> IO.iodata_to_binary() |> :json.decode()
    end
  end

  defmodule Capture do
    @behaviour MutagenEx.Pipeline.IoFacade

    @impl MutagenEx.Pipeline.IoFacade
    def emit(iodata, code, config) do
      send(self(), {code, iodata |> IO.iodata_to_binary() |> :json.decode(), config})
    end
  end
end
