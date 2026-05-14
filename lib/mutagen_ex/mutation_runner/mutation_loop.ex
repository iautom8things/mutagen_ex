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
  #      Classification is `:timeout` whether the task exited via the
  #      graceful or supervised-kill path — r4 cares about the
  #      wall-clock budget, not which kill mechanism cleared it.
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
               cancel_mode: cancel_mode()
             }}
          | {:error, term(),
             %{
               stderr: binary(),
               snapshot_before: snapshot(),
               snapshot_after: snapshot(),
               cancel_mode: cancel_mode()
             }}

  @typedoc "Input map."
  @type input :: %{
          required(:test_modules) => [{module(), map()}],
          required(:timeout_ms) => pos_integer(),
          optional(:ex_unit) => module(),
          optional(:ex_unit_server) => module(),
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

      :timeout ->
        {:timeout, meta}

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
    ex_unit = Map.get(input, :ex_unit, ExUnit)
    server = Map.get(input, :ex_unit_server, ExUnit.Server)
    # Per `mutagen.decision.supervision_tree`: the per-site task runs
    # under the named `MutagenEx.TaskSup` in production. Tests can
    # inject their own `Task.Supervisor` pid (or name) via `:task_sup`
    # for isolation. Either an atom name or a pid is acceptable —
    # `Task.Supervisor.async_nolink/2` accepts both.
    task_sup = Map.get(input, :task_sup, MutagenEx.TaskSup)

    task =
      Task.Supervisor.async_nolink(task_sup, fn ->
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
        {{:ok, result}, :n_a}

      {:ok, {:error, reason}} ->
        {{:error, reason}, :n_a}

      nil ->
        # r4: timeout fired. Cooperatively cancel first so any
        # Code.Server load locks (or other VM-internal locks) the
        # task holds can be released cleanly before we escalate to
        # supervised termination. See
        # `mutagen.decision.timeout_handling` and
        # `mutagen.decision.supervision_tree`.
        cancel_on_timeout(task, grace, task_sup)

      {:exit, reason} ->
        {{:error, {:task_exited, reason}}, :n_a}
    end
  end

  # Two-phase cancellation. Phase 1 is `Task.shutdown(task, grace_ms)`,
  # which dispatches `Process.exit(pid, :shutdown)` — a trappable signal
  # that lets a task in a normal `receive` (or one that traps exits)
  # finish unwinding. If phase 1 produced a result we still classify
  # against the original outcome: a task that returned `{:ok, result}`
  # during the grace window is honored as `:completed`; a task that
  # returned `{:error, reason}` is `:error`; an exit with a non-normal
  # reason or no result means the task is still occupying the runner's
  # wall-clock budget — escalate via the supervisor.
  #
  # Phase 2, `Task.Supervisor.terminate_child/2`, is the last-resort
  # escape for tasks that did not exit in the grace window. Routing
  # through the supervisor (rather than `Task.shutdown(:brutal_kill)`)
  # is what propagates `:shutdown` through the task's link tree to
  # reap descendants — see `mutagen.decision.supervision_tree`.
  defp cancel_on_timeout(task, grace_ms, task_sup) when grace_ms > 0 do
    case Task.shutdown(task, grace_ms) do
      {:ok, {:ok, result}} ->
        # Task happened to finish during the grace window AND returned
        # a clean result. Classify it as completed; the timeout did
        # not actually need to fire.
        {{:ok, result}, :graceful}

      {:ok, {:error, reason}} ->
        # Task finished during the grace window but the inner body
        # raised/caught. Same classification path as the no-timeout
        # error branch above.
        {{:error, reason}, :graceful}

      nil ->
        # Grace window expired and `Task.shutdown/2` decided NOT to
        # escalate internally (rare with traps off; common with the
        # normal `Process.sleep`-style tasks that are killed by the
        # initial `:shutdown` signal). The result was lost. Escalate
        # explicitly through the supervisor for completeness — its
        # behaviour on an already-dead task is `{:error, :not_found}`
        # which `brutal_shutdown/2` treats as `:timeout`.
        brutal_shutdown(task, task_sup)

      {:exit, :killed} ->
        # `Task.shutdown(task, grace_ms)` internally escalates to
        # `Process.exit(pid, :kill)` after the grace window if the
        # task is still running AND was trapping exits (e.g. it
        # ignored the `:shutdown` signal). The task is already
        # cleared; no second escalation is needed. From the
        # cancellation taxonomy's perspective this IS the brutal
        # path — the cooperative phase ran out the clock and
        # `Task.shutdown` itself did the kill — so cancel_mode is
        # `:brutal`. Flush the monitor explicitly so the stale
        # `:DOWN` Task.shutdown produced does not survive into the
        # next site's mailbox.
        Process.demonitor(task.ref, [:flush])
        {:timeout, :brutal}

      {:exit, _other_reason} ->
        # Task exited during grace for some other reason (e.g. a
        # raise that the task didn't rescue). Treat as timeout —
        # the wall-clock budget elapsed regardless of the exit
        # path.
        Process.demonitor(task.ref, [:flush])
        {:timeout, :brutal}
    end
  end

  defp cancel_on_timeout(task, _grace_ms, task_sup) do
    # grace_ms == 0 ⇒ skip the cooperative phase entirely. Preserved as
    # an escape hatch for tests that deliberately exercise the
    # supervised-kill path.
    brutal_shutdown(task, task_sup)
  end

  # Phase-2 escalation. Capture any racing result the task may have
  # produced between the grace window expiring and our `terminate_child`
  # call (preserving the `pre_kill_result = Task.yield(task, 0)` shape
  # of the original two-phase cancel), then route the kill through the
  # supervisor so `:shutdown` propagates through the link tree, and
  # finally flush the monitor so the stale `:DOWN` the dying task is
  # about to emit does not accumulate in the runner's mailbox across
  # timeout sites.
  defp brutal_shutdown(task, task_sup) do
    pre_kill_result = Task.yield(task, 0)
    _ = Task.Supervisor.terminate_child(task_sup, task.pid)
    Process.demonitor(task.ref, [:flush])

    case pre_kill_result do
      {:ok, {:ok, result}} -> {{:ok, result}, :brutal}
      {:ok, {:error, reason}} -> {{:error, reason}, :brutal}
      _ -> {:timeout, :brutal}
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
