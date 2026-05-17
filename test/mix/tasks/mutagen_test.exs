defmodule Mix.Tasks.MutagenTest do
  use ExUnit.Case, async: false

  alias MutagenEx.Config

  defmodule CliStub do
    @moduledoc false
    @behaviour MutagenEx.Pipeline.CliFacade

    @impl MutagenEx.Pipeline.CliFacade
    def parse(_argv), do: {:ok, %Config{scopes: ["lib/foo.ex"], tests: ["test/foo_test.exs"]}}
  end

  defmodule ScopeAbort do
    @moduledoc false
    @behaviour MutagenEx.Pipeline.ScopeFacade

    @impl MutagenEx.Pipeline.ScopeFacade
    def resolve(_target, _opts), do: {:error, :module_not_found, %{message: "stop"}}
  end

  defmodule IoStub do
    @moduledoc false
    @behaviour MutagenEx.Pipeline.IoFacade

    @impl MutagenEx.Pipeline.IoFacade
    def emit(_iodata, _code, _config), do: :ok
  end

  defmodule ScopeStub do
    @moduledoc false
    @behaviour MutagenEx.Pipeline.ScopeFacade

    @impl MutagenEx.Pipeline.ScopeFacade
    def resolve(target, opts) do
      apply(Process.get({:phase_fun, :scope}), [target, opts])
    end
  end

  defmodule CapturingIoStub do
    @moduledoc false
    @behaviour MutagenEx.Pipeline.IoFacade

    @impl MutagenEx.Pipeline.IoFacade
    def emit(iodata, code, config) do
      send(Process.get(:capture_target), {:io, iodata, code, config})
      :ok
    end
  end

  defp fail_scope(target, _opts) do
    {:error, :module_not_found, %{target: target, message: "fake-scope refusal"}}
  end

  describe "Mix.Tasks.Mutagen.run/2 preamble boundary (mutagen.cli.s14b)" do
    test "run/2 does not invoke the runtime preamble" do
      :erlang.trace(self(), true, [:call])
      :erlang.trace_pattern({Mix.Task, :run, 1}, true, [:local])

      try do
        assert {:aborted, :module_not_found, _report} =
                 Mix.Tasks.Mutagen.run([], %{
                   cli: CliStub,
                   scope: ScopeAbort,
                   io: IoStub
                 })

        refute_received {:trace, _pid, :call, {Mix.Task, :run, ["loadpaths"]}}
        refute_received {:trace, _pid, :call, {Mix.Task, :run, ["compile"]}}
      after
        :erlang.trace_pattern({Mix.Task, :run, 1}, false, [:local])
        :erlang.trace(self(), false, [:call])
      end
    end
  end

  @tag :unsafe_json_path
  test "unsafe --json path is rejected without writing to that path" do
    rejected_path =
      Path.join(System.tmp_dir!(), "mutagen-rejected-#{System.unique_integer([:positive])}.json")

    on_exit(fn -> File.rm(rejected_path) end)

    dispatch = %{
      scope: __MODULE__.ScopeStub,
      io: __MODULE__.CapturingIoStub
    }

    Process.put(:capture_target, self())
    Process.put({:phase_fun, :scope}, &fail_scope/2)

    assert {:aborted, :unsafe_json_path, _report} =
             Mix.Tasks.Mutagen.run(
               [
                 "--scope",
                 "lib/foo.ex",
                 "--tests",
                 "test/foo_test.exs",
                 "--json",
                 rejected_path
               ],
               dispatch
             )

    assert_received {:io, iodata, code, config}
    assert code != 0
    assert config.json_path == nil
    refute File.exists?(rejected_path)

    decoded =
      iodata
      |> IO.iodata_to_binary()
      |> :json.decode()

    assert decoded["aborted"] == true
    assert decoded["abort_reason"] == "unsafe_json_path"
  end
end
