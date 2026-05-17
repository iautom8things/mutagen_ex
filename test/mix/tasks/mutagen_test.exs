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
end
