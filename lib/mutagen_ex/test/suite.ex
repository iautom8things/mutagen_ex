defmodule MutagenEx.Test.Suite do
  @moduledoc false

  alias MutagenEx.JsonReporter
  alias JsonReporter.Sanitizer

  def run(ex_unit, phase) do
    {:ok, ex_unit.run()}
  rescue
    error -> failed(phase, "raised", Exception.message(error))
  catch
    kind, reason ->
      failed(phase, "caught #{kind}", Exception.format_banner(kind, reason, __STACKTRACE__))
  end

  defp failed(phase, how, message) do
    {:error, :ex_unit_run_failed,
     %{message: Sanitizer.clean("ExUnit.run/0 #{how} during #{phase}: #{message}")}}
  end

  def require_tests(%{total: total} = stats, filter, phase) do
    excluded = Map.get(stats, :excluded, 0)
    skipped = Map.get(stats, :skipped, 0)

    if total > excluded + skipped or Map.get(stats, :failures, 0) > 0 do
      :ok
    else
      {:error, :no_tests_run,
       %{
         message: "ExUnit executed no tests during #{phase}",
         phase: phase,
         excluded: excluded,
         skipped: skipped,
         include: Enum.map(filter.include, &JsonReporter.filter_to_wire/1),
         exclude: Enum.map(filter.exclude, &JsonReporter.filter_to_wire/1)
       }}
    end
  end

  def require_tests(_, _, phase), do: failed(phase, "failed", "unexpected suite statistics")
end
