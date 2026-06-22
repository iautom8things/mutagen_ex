defmodule MutagenEx.Test.CoverGuard do
  @moduledoc """
  Detects whether the test suite is running under `mix test --cover`.

  Under `mix test --cover` the Mix harness owns the BEAM-wide `:cover_server`
  singleton and has cover-compiled every project module before the suite
  starts. Several test modules carry a defensive `on_exit` that calls
  `:cover.stop/0` to clean up after tests that instrument cover themselves.
  That defensive stop is harmful under `--cover`: stopping cover discards the
  harness's instrumentation, so by report time zero modules remain compiled
  and the coverage reporter crashes with `Enum.EmptyError` in
  `Mix.Tasks.Test.Coverage`.

  `running_under_cover?/0` lets those `on_exit` hooks skip the stop when the
  harness owns cover. The signal is the harness's pre-compiled module set:
  under `--cover` `:cover` is loaded and reports many project modules; in a
  normal run `:cover` is unloaded and reports none.
  """

  @doc """
  Returns `true` when the suite is running under `mix test --cover`.
  """
  def running_under_cover? do
    case Process.whereis(:cover_server) do
      nil ->
        false

      pid when is_pid(pid) ->
        # A test that started its own cover session (via CoverageRunner)
        # compiles only its handful of in-scope modules; the harness
        # pre-compiles the whole project. Use a threshold so a stray
        # single-module session is not mistaken for the harness.
        cover_module_count() > 1
    end
  end

  defp cover_module_count do
    apply(:cover, :modules, []) |> length()
  rescue
    _ -> 0
  catch
    _, _ -> 0
  end
end
