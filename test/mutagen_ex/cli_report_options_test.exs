defmodule MutagenEx.CliReportOptionsTest do
  use ExUnit.Case, async: true

  alias MutagenEx.JsonReporter
  alias MutagenEx.JsonReporter.Report

  @tag spec: "mutagen.cli.r31"
  test "an older OTP gets a startup error without calling its JSON encoder" do
    worker =
      Task.async(fn ->
        receive do
          :run ->
            dispatch = %{otp_release: "26", io: __MODULE__.Capture, cli: nil}
            assert {:aborted, :unsupported_otp_version, _} = Mix.Tasks.Mutagen.run([], dispatch)
            assert_received {2, report, _config}
            report
        end
      end)

    Code.ensure_loaded!(:json)
    session = :trace.session_create(:startup_json_test, self(), [])

    try do
      assert :trace.function(session, {:json, :_, :_}, true, []) > 0
      assert :trace.process(session, worker.pid, true, [:call, :arity]) == 1
      send(worker.pid, :run)

      assert %{
               "aborted" => true,
               "abort_reason" => "unsupported_otp_version",
               "details" => %{
                 "actual" => "26",
                 "hint" => "Run Mutagen with Erlang/OTP 27 or later."
               },
               "meta" => %{"otp_version" => "26", "max_concurrency" => 1}
             } = Task.await(worker)

      delivered = :trace.delivered(session, :all)
      assert_receive {:trace_delivered, :all, ^delivered}
      refute_received {:trace, _, :call, {:json, _, _}}
    after
      :trace.session_destroy(session)
    end
  end

  @tag spec: "mutagen.cli.r32"
  test "the CLI and Mix project accept Elixir from 1.18.0" do
    dispatch = %{elixir_version: "1.17.3", io: __MODULE__.Capture, cli: nil}

    assert {:aborted, :unsupported_elixir_version, _} = Mix.Tasks.Mutagen.run([], dispatch)
    assert_received {2, report, _config}

    assert %{
             "aborted" => true,
             "abort_reason" => "unsupported_elixir_version",
             "details" => %{
               "actual" => "1.17.3",
               "hint" => "Run Mutagen with Elixir 1.18.0 or later."
             },
             "meta" => %{"elixir_version" => "1.17.3"}
           } = report

    opts = %{elixir_version: "1.18.0", io: __MODULE__.Capture}
    assert {:aborted, :missing_scope, _} = Mix.Tasks.Mutagen.run([], opts)
    assert_received {2, %{"abort_reason" => "missing_scope"}, _config}

    requirement = MutagenEx.MixProject.project()[:elixir]
    assert Version.match?("1.18.0", requirement)
    refute Version.match?("1.17.3", requirement)
  end

  @tag spec: "mutagen.json_schema.r26"
  test "the dispatch limit is recorded and parallel runs warn even on early abort" do
    warning = "Verdicts are unreliable in experimental parallel mode."

    for {args, limit, warnings} <- [{[], 1, []}, {["--max-concurrency", "2"], 2, [warning]}] do
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
      send(self(), {code, iodata |> IO.iodata_to_binary() |> JSON.decode!(), config})
    end
  end
end
