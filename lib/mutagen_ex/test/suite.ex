defmodule MutagenEx.Test.Suite do
  @moduledoc false

  def run(ex_unit, phase) do
    {:ok, ex_unit.run()}
  rescue
    error ->
      failed(
        phase,
        "raised",
        Exception.message(error),
        MutagenEx.Runtime.exception_facts(error, __STACKTRACE__)
      )
  catch
    kind, reason ->
      facts = if is_atom(reason), do: %{reason: reason}, else: %{}

      failed(
        phase,
        "caught #{kind}",
        Exception.format_banner(kind, reason, __STACKTRACE__),
        facts
      )
  end

  defp failed(phase, how, message, facts \\ %{}) do
    {:error, :ex_unit_run_failed,
     Map.merge(facts, %{phase: phase, message: "ExUnit.run/0 #{how} during #{phase}: #{message}"})}
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
         include: filter.include,
         exclude: filter.exclude
       }}
    end
  end

  def require_tests(_, _, phase), do: failed(phase, "failed", "unexpected suite statistics")
end
