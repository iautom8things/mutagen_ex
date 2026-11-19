defmodule MutagenEx.MutationRunner.MutationLoop do
  @moduledoc false

  # Private to `MutagenEx.MutationRunner` per
  # `mutagen.decision.mutation_loop_private`.
  #
  # Owns three responsibilities that the runner needs once per mutation
  # site but baseline/coverage do NOT need:
  #
  #   1. **Timeout wrapping with cooperative cancellation.**
  #      `Task.Supervisor.async_nolink(task_sup, fn -> ... end)` +
  #      `Task.yield(timeout_ms)` is the happy path. On timeout the
  #      loop drives a two-phase cancellation:
  #
  #        a. `Task.shutdown(task, cancel_grace_ms)` — issues a
  #           trappable `:shutdown` exit. A test process that is in a
  #           normal `receive` or that traps exits at a hot loop
  #           checkpoint can terminate cleanly here, releasing any
  #           locks it holds (in particular the Code.Server's per-module
  #           load lock — see `mutagen.decision.timeout_handling`).
  #        b. If the task is still alive after the grace window,
  #           `Task.Supervisor.terminate_child(task_sup, task.pid)`.
  #           This routes the kill through the supervisor's child table
  #           (synchronous removal of the dead child) and dispatches
  #           `Process.exit(_, :shutdown)`, which propagates through
  #           the task's link tree to reap descendants — the untrapped-
  #           link and OTP-supervised-subtree classes per
  #           `mutagen.decision.supervision_tree`. Immediately after
  #           `terminate_child/2`, the loop calls
  #           `Process.demonitor(task.ref, [:flush])` so the dying
  #           task's stale `:DOWN` does not accumulate in the runner's
  #           mailbox across timeout sites.
  #
  #      When fail-fast is on, a failure recorded before the deadline
  #      still counts if the rest of the runner takes too long to exit.
  #
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

  # Default grace window the cooperative-shutdown phase waits for the
  # task to exit cleanly before escalating to brutal_kill. Small enough
  # to keep per-site latency in the same envelope as the original
  # brutal-only path; large enough that a task in a normal `receive`
  # block has time to process the `:shutdown` exit signal and unwind.
  @default_cancel_grace_ms 100

  alias MutagenEx.Test.ExUnitServer

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

  @typedoc "Mechanism the timeout cancellation actually used."
  @type cancel_mode :: :graceful | :brutal | :n_a

  @typedoc "Outcome of a single `run/1` call."
  @type outcome ::
          {:completed, exunit_result(),
           %{
             stderr: binary(),
             snapshot_before: snapshot(),
             snapshot_after: snapshot(),
             cancel_mode: cancel_mode()
           }}
          | {:timeout,
             %{
               stderr: binary(),
               snapshot_before: snapshot(),
               snapshot_after: snapshot(),
               cancel_mode: cancel_mode(),
               failure_recorded?: boolean()
             }}
          | {:error, term(),
             %{
               stderr: binary(),
               snapshot_before: snapshot(),
               snapshot_after: snapshot(),
               cancel_mode: cancel_mode()
             }}

  @typedoc """
  Input map. The `:ex_unit`, `:ex_unit_server`, and `:capture_io` keys
  name modules implementing the corresponding `MutagenEx.Test.*Facade`
  behaviour (defaults: `MutagenEx.Test.ExUnit`,
  `MutagenEx.Test.ExUnitServer`, `MutagenEx.Test.CaptureIo`).
  """
  @type input :: %{
          required(:test_modules) => [{module(), map()}],
          required(:timeout_ms) => pos_integer(),
          optional(:ex_unit) => module(),
          optional(:ex_unit_server) => module(),
          optional(:failure_times) => :ets.tab() | nil,
          optional(:serial?) => boolean(),
          optional(:capture_io) => module(),
          optional(:cancel_grace_ms) => non_neg_integer(),
          optional(:task_sup) => atom() | pid()
        }

  @spec run(input()) :: outcome()
  def run(input) when is_map(input) do
    snapshot_before = take_snapshot()

    {stderr, {body_result, cancel_mode}} =
      capture_stderr(input, fn ->
        execute_with_timeout(input)
      end)

    snapshot_after = take_snapshot()

    meta = %{
      stderr: stderr,
      snapshot_before: snapshot_before,
      snapshot_after: snapshot_after,
      cancel_mode: cancel_mode
    }

    case body_result do
      {:ok, exunit_result} ->
        {:completed, exunit_result, meta}

      {:timeout, failure_recorded?} ->
        {:timeout, Map.put(meta, :failure_recorded?, failure_recorded?)}

      {:error, reason} ->
        {:error, reason, meta}
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
    grace = Map.get(input, :cancel_grace_ms, @default_cancel_grace_ms)
    test_modules = input.test_modules
    ex_unit = Map.get(input, :ex_unit, MutagenEx.Test.ExUnit)
    server = Map.get(input, :ex_unit_server, ExUnitServer)
    failures = Map.get(input, :failure_times)
    # Per `mutagen.decision.supervision_tree`: the per-site task runs
    # under the named `MutagenEx.TaskSup` in production. Tests can
    # inject their own `Task.Supervisor` pid (or name) via `:task_sup`
    # for isolation. Either an atom name or a pid is acceptable —
    # `Task.Supervisor.async_nolink/2` accepts both.
    task_sup = Map.get(input, :task_sup, MutagenEx.TaskSup)

    task =
      Task.Supervisor.async_nolink(task_sup, fn ->
        Enum.each(test_modules, fn {mod, cfg} -> server.add_module(mod, cfg) end)
        result = run_exunit(ex_unit)
        {System.monotonic_time(), result}
      end)

    deadline = System.monotonic_time() + System.convert_time_unit(timeout, :millisecond, :native)

    result =
      case Task.yield(task, timeout) do
        {:ok, {finished_at, result}} when finished_at <= deadline ->
          {result, :n_a}

        {:ok, _late_reply} ->
          timeout_result(input, server, failures, task.pid, deadline, :n_a)

        nil ->
          cancel_mode = cancel_on_timeout(task, grace, task_sup)
          timeout_result(input, server, failures, task.pid, deadline, cancel_mode)

        {:exit, reason} ->
          if System.monotonic_time() <= deadline do
            {{:error, {:task_exited, reason}}, :n_a}
          else
            timeout_result(input, server, failures, task.pid, deadline, :n_a)
          end
      end

    if failures, do: :ets.delete(failures, task.pid)
    result
  end

  defp run_exunit(ex_unit) do
    {:ok, ex_unit.run()}
  rescue
    e -> {:error, {:run_raised, Exception.message(e)}}
  catch
    kind, value -> {:error, {:run_caught, kind, value}}
  end

  defp timeout_result(input, server, failures, runner, deadline, cancel_mode) do
    if Map.get(input, :serial?, true), do: server.discard_pending_modules()
    {{:timeout, failure_before_deadline?(failures, runner, deadline)}, cancel_mode}
  end

  defp failure_before_deadline?(nil, _runner, _deadline), do: false

  defp failure_before_deadline?(failures, runner, deadline) do
    case :ets.lookup(failures, runner) do
      [{^runner, time}] -> time <= deadline
      [] -> false
    end
  end

  # Shutdown serves only to reap the overdue task. Its reply cannot supply a verdict.
  defp cancel_on_timeout(task, grace_ms, task_sup) when grace_ms > 0 do
    case Task.shutdown(task, grace_ms) do
      nil -> brutal_shutdown(task, task_sup)
      {:exit, :killed} -> :brutal
      _ -> :graceful
    end
  end

  defp cancel_on_timeout(task, _grace_ms, task_sup), do: brutal_shutdown(task, task_sup)

  defp brutal_shutdown(task, task_sup) do
    _ = Task.Supervisor.terminate_child(task_sup, task.pid)
    _ = Task.yield(task, 0)
    Process.demonitor(task.ref, [:flush])
    :brutal
  end

  # ---- stderr capture ----

  defp capture_stderr(input, fun) do
    capture_io = Map.get(input, :capture_io, MutagenEx.Test.CaptureIo)

    # `with_io/2` returns `{closure_result, captured_io}` directly. Per
    # `mutagen-wrd.23` this replaces the older
    # `make_ref/Process.put/Process.get` smuggle that relied on the
    # (undocumented) fact that `capture_io/2` runs its closure in the
    # calling process.
    {body_result, output} = capture_io.with_io(:stderr, fun)

    {output, body_result}
  end
end
