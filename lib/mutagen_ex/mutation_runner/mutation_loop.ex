defmodule MutagenEx.MutationRunner.MutationLoop do
  @moduledoc false

  # Private to `MutagenEx.MutationRunner` per
  # `mutagen.decision.mutation_loop_private`.
  #
  # Owns three responsibilities that the runner needs once per mutation
  # site but baseline/coverage do NOT need:
  #
  #   1. **Timeout wrapping.** `Task.async + Task.yield(timeout_ms) +
  #      Task.shutdown(:brutal_kill)` (the spike-blessed shape from S2).
  #      A test that hangs is killed without grace; classification becomes
  #      `:timeout`.
  #   2. **Stderr capture.** `ExUnit.CaptureIO.capture_io(:stderr, fn -> ...)`
  #      so compiler warnings or test-emitted stderr never reach the user's
  #      terminal. The captured string is returned alongside the outcome
  #      and lands in the JSON's `results[i].warnings` field.
  #   3. **Pre/post state snapshots.** `length(Process.registered())`,
  #      `length(:ets.all())`, and `:persistent_term.info().count`. The
  #      runner uses the deltas to flag `tainted_predecessors: true`.
  #
  # Module is documented with `@moduledoc false` because its API is
  # internal — the runner is its only caller; tests reach it through the
  # runner's surface per `mutagen.decision.mutation_loop_private`.
  #
  # ## Per-mutation test re-running
  #
  # Each per-mutation cycle needs to re-invoke `ExUnit.run/0` against the
  # same test modules that baseline ran. ExUnit consumes the registered
  # module list each time `run/0` returns, so the loop re-adds the cited
  # modules via `ExUnit.Server.add_module/2` before each run, using the
  # exact `%{async?: false, group: nil, parameterize: nil}` shape the S2
  # spike validated against Elixir 1.19.5 / OTP 28.

  @typedoc "ExUnit-shaped run result map (subset)."
  @type exunit_result :: %{
          optional(:failures) => non_neg_integer(),
          optional(:total) => non_neg_integer(),
          optional(:excluded) => non_neg_integer(),
          optional(:skipped) => non_neg_integer()
        }

  @typedoc "Pre/post state snapshot."
  @type snapshot :: %{
          processes: non_neg_integer(),
          ets: non_neg_integer(),
          persistent_terms: non_neg_integer()
        }

  @typedoc "Outcome of a single `run/1` call."
  @type outcome ::
          {:completed, exunit_result(),
           %{stderr: binary(), snapshot_before: snapshot(), snapshot_after: snapshot()}}
          | {:timeout,
             %{stderr: binary(), snapshot_before: snapshot(), snapshot_after: snapshot()}}
          | {:error, term(),
             %{stderr: binary(), snapshot_before: snapshot(), snapshot_after: snapshot()}}

  @typedoc "Input map."
  @type input :: %{
          required(:test_modules) => [{module(), map()}],
          required(:timeout_ms) => pos_integer(),
          optional(:ex_unit) => module(),
          optional(:ex_unit_server) => module(),
          optional(:capture_io) => module(),
          optional(:task_supervisor) => module()
        }

  @spec run(input()) :: outcome()
  def run(input) when is_map(input) do
    snapshot_before = take_snapshot()

    {stderr, body_result} =
      capture_stderr(input, fn ->
        execute_with_timeout(input)
      end)

    snapshot_after = take_snapshot()

    case body_result do
      {:ok, exunit_result} ->
        {:completed, exunit_result,
         %{
           stderr: stderr,
           snapshot_before: snapshot_before,
           snapshot_after: snapshot_after
         }}

      :timeout ->
        {:timeout,
         %{
           stderr: stderr,
           snapshot_before: snapshot_before,
           snapshot_after: snapshot_after
         }}

      {:error, reason} ->
        {:error, reason,
         %{
           stderr: stderr,
           snapshot_before: snapshot_before,
           snapshot_after: snapshot_after
         }}
    end
  end

  # ---- snapshots ----

  @spec take_snapshot() :: snapshot()
  def take_snapshot do
    %{
      processes: length(Process.registered()),
      ets: length(:ets.all()),
      persistent_terms: :persistent_term.info().count
    }
  end

  @spec snapshot_delta(snapshot(), snapshot()) :: snapshot()
  def snapshot_delta(before, after_) do
    %{
      processes: after_.processes - before.processes,
      ets: after_.ets - before.ets,
      persistent_terms: after_.persistent_terms - before.persistent_terms
    }
  end

  @spec snapshot_grew?(snapshot()) :: boolean()
  def snapshot_grew?(delta) do
    delta.processes > 0 or delta.ets > 0 or delta.persistent_terms > 0
  end

  # ---- timeout + run ----

  defp execute_with_timeout(input) do
    timeout = input.timeout_ms
    test_modules = input.test_modules
    ex_unit = Map.get(input, :ex_unit, ExUnit)
    server = Map.get(input, :ex_unit_server, ExUnit.Server)

    task =
      Task.async(fn ->
        # Re-register every cited test module so ExUnit.run/0 picks them
        # up. The shape `%{async?: false, group: nil, parameterize: nil}`
        # is what the S2 spike validated against Elixir 1.19.5/OTP 28; if
        # ExUnit's internal config struct ever changes, this is the line
        # to update — and the spike will catch the regression.
        Enum.each(test_modules, fn {mod, cfg} ->
          apply(server, :add_module, [mod, cfg])
        end)

        try do
          {:ok, apply(ex_unit, :run, [])}
        rescue
          e ->
            {:error, {:run_raised, Exception.message(e)}}
        catch
          kind, value ->
            {:error, {:run_caught, kind, value}}
        end
      end)

    case Task.yield(task, timeout) do
      {:ok, {:ok, result}} ->
        {:ok, result}

      {:ok, {:error, reason}} ->
        {:error, reason}

      nil ->
        # r4: brutal kill on timeout. The killed task may have left
        # named processes / ETS tables / persistent terms behind; the
        # post-snapshot will flag any growth.
        case Task.shutdown(task, :brutal_kill) do
          {:ok, {:ok, result}} -> {:ok, result}
          {:ok, {:error, reason}} -> {:error, reason}
          _ -> :timeout
        end

      {:exit, reason} ->
        {:error, {:task_exited, reason}}
    end
  end

  # ---- stderr capture ----

  defp capture_stderr(input, fun) do
    capture_io = Map.get(input, :capture_io, ExUnit.CaptureIO)

    # ExUnit.CaptureIO captures only what's written via the configured
    # device. The function we pass returns the body result; we wrap it
    # in `Process.put`/`get` to read it back outside the capture closure.
    ref = make_ref()

    output =
      apply(capture_io, :capture_io, [
        :stderr,
        fn ->
          result = fun.()
          Process.put({__MODULE__, ref}, result)
        end
      ])

    body_result = Process.get({__MODULE__, ref})
    Process.delete({__MODULE__, ref})

    {output, body_result}
  end
end
