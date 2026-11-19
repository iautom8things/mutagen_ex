defmodule MutagenEx.MutationRunner.MutationLoop do
  @moduledoc false

  # Private to `MutagenEx.MutationRunner` per
  # `mutagen.decision.mutation_loop_private`.
  #
  # Owns three responsibilities that the runner needs once per mutation
  # site but baseline/coverage do NOT need:
  #
  #   1. **Timeout and cancellation.** The task timestamps its reply.
  #      Replies after the deadline cannot supply a verdict. If no reply
  #      arrives, Task.shutdown/2 gives the task a grace period before
  #      killing it. A zero grace period goes straight to supervisor
  #      termination.
  #
  #      When fail-fast is on, a failure recorded before the deadline
  #      still counts if the rest of the runner takes too long to exit.
  #
  #   2. **Stderr capture.** `ExUnit.CaptureIO.capture_io(:stderr, fn -> ...)`
  #      so compiler warnings or test-emitted stderr never reach the user's
  #      terminal. The captured string is returned alongside the outcome
  #      and lands in the JSON's `results[i].warnings` field.
  #   3. **Pre/post state snapshots.** The runner uses new process names,
  #      ETS tables and persistent term keys to flag later results.
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
  # cases before each run with their discovered registration options.

  # Default grace window the cooperative-shutdown phase waits for the
  # task to exit cleanly before escalating to brutal_kill. Small enough
  # to keep per-site latency in the same envelope as the original
  # brutal-only path; large enough that a task in a normal `receive`
  # block has time to process the `:shutdown` exit signal and unwind.
  @default_cancel_grace_ms 100

  alias MutagenEx.Test.{ExUnitServer, RunGroup}

  @typedoc "ExUnit-shaped run result map (subset)."
  @type exunit_result :: %{
          optional(:failures) => non_neg_integer(),
          optional(:total) => non_neg_integer(),
          optional(:excluded) => non_neg_integer(),
          optional(:skipped) => non_neg_integer()
        }

  @typedoc "Pre/post state snapshot."
  @type snapshot :: %{
          processes: MapSet.t(atom()),
          ets: %{optional(atom()) => pos_integer()},
          persistent_terms: MapSet.t(term())
        }

  @typedoc "Outcome of a single `run/1` call."
  @type outcome ::
          {:completed, exunit_result(),
           %{
             stderr: binary(),
             snapshot_before: snapshot(),
             snapshot_after: snapshot(),
             host_warnings: [term()]
           }}
          | {:timeout,
             %{
               stderr: binary(),
               snapshot_before: snapshot(),
               snapshot_after: snapshot(),
               host_warnings: [term()],
               failure_recorded?: boolean()
             }}
          | {:error, term(),
             %{
               stderr: binary(),
               snapshot_before: snapshot(),
               snapshot_after: snapshot(),
               host_warnings: [term()]
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
          optional(:snapshot_before) => snapshot() | nil,
          optional(:capture_io) => module(),
          optional(:cancel_grace_ms) => non_neg_integer(),
          optional(:task_sup) => atom() | pid()
        }

  @spec run(input()) :: outcome()
  def run(input) when is_map(input) do
    snapshot_before = Map.get(input, :snapshot_before) || take_snapshot()

    {stderr, {body_result, host_warnings}} =
      capture_stderr(input, fn ->
        execute_with_timeout(input)
      end)

    snapshot_after = take_snapshot()

    meta = %{
      stderr: stderr,
      snapshot_before: snapshot_before,
      snapshot_after: snapshot_after,
      host_warnings: host_warnings
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
      processes: MapSet.new(Process.registered()),
      ets: ets_name_counts(),
      persistent_terms: MapSet.new(:persistent_term.get(), &elem(&1, 0))
    }
  end

  defp ets_name_counts do
    Enum.reduce(:ets.all(), %{}, fn table, counts ->
      name = :ets.info(table, :name)

      if name == :undefined and :ets.info(table, :owner) == :undefined do
        counts
      else
        Map.update(counts, name, 1, &(&1 + 1))
      end
    end)
  end

  @typep delta :: %{atom() => %{optional(term()) => pos_integer()}}

  @spec snapshot_delta(snapshot(), snapshot()) :: delta()
  def snapshot_delta(before, after_) do
    ets =
      for {name, count} <- after_.ets,
          (growth = count - Map.get(before.ets, name, 0)) > 0,
          into: %{},
          do: {name, growth}

    persistent_terms =
      for key <- MapSet.difference(after_.persistent_terms, before.persistent_terms),
          not bookkeeping_key?(key),
          into: %{},
          do: {key, 1}

    %{
      processes: additions(before.processes, after_.processes),
      ets: ets,
      persistent_terms: persistent_terms
    }
  end

  defp additions(before, after_), do: Map.new(MapSet.difference(after_, before), &{&1, 1})

  defp bookkeeping_key?({:logger_config, module}) when is_atom(module),
    do: :logger.get_module_level(module) == []

  defp bookkeeping_key?(:elixir_erl_compiler), do: true
  defp bookkeeping_key?(_), do: false

  @spec snapshot_grew?(delta()) :: boolean()
  def snapshot_grew?(delta), do: Enum.any?(delta, fn {_, entries} -> map_size(entries) > 0 end)

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

    destination = Process.group_leader()
    start = make_ref()
    host = Map.get_lazy(input, :host_snapshot, &RunGroup.snapshot/0)
    group = RunGroup.start(destination)

    task =
      Task.Supervisor.async_nolink(task_sup, fn ->
        receive do
          ^start -> :ok
        end

        Process.group_leader(self(), group)
        Enum.each(test_modules, fn {mod, cfg} -> server.add_module(mod, cfg) end)
        result = MutagenEx.Test.Suite.run(ex_unit, :mutation)
        {System.monotonic_time(), result}
      end)

    tracker = RunGroup.track(group, task.pid)
    send(task.pid, start)
    deadline = System.monotonic_time() + System.convert_time_unit(timeout, :millisecond, :native)

    try do
      result =
        case Task.yield(task, timeout) do
          {:ok, {finished_at, result}} when finished_at <= deadline ->
            site_result(result)

          {:ok, _late_reply} ->
            timeout_result(failures, task.pid, deadline)

          nil ->
            cancel_on_timeout(task, grace, task_sup)
            timeout_result(failures, task.pid, deadline)

          {:exit, reason} ->
            if System.monotonic_time() <= deadline do
              {:error, {:task_exited, reason}}
            else
              timeout_result(failures, task.pid, deadline)
            end
        end

      if failures, do: :ets.delete(failures, task.pid)
      body_result = finish_group(result, group, host.processes, tracker, input, server)
      {body_result, RunGroup.host_warnings(host, not match?({:ok, _}, body_result))}
    catch
      kind, reason ->
        RunGroup.stop(group, :reap, host.processes, tracker)
        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  defp finish_group(
         {:ok, _} = completed,
         group,
         host_processes,
         tracker,
         _input,
         _server
       ) do
    RunGroup.stop(group, :release, host_processes, tracker)
    completed
  end

  defp finish_group(unsuccessful, group, host_processes, tracker, input, server) do
    # ExUnit's test and module workers are monitored, so killing the
    # runner leaves them alive. They inherit its group leader on spawn.
    RunGroup.stop(group, :reap, host_processes, tracker)

    if Map.get(input, :serial?, true) do
      server.discard_pending_modules()
    end

    unsuccessful
  end

  defp site_result({:error, :ex_unit_run_failed, details}),
    do: {:error, {:ex_unit_run_failed, details}}

  defp site_result(result), do: result

  defp timeout_result(failures, runner, deadline),
    do: {:timeout, failure_before_deadline?(failures, runner, deadline)}

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
      _ -> :ok
    end
  end

  defp cancel_on_timeout(task, _grace_ms, task_sup), do: brutal_shutdown(task, task_sup)

  defp brutal_shutdown(task, task_sup) do
    _ = Task.Supervisor.terminate_child(task_sup, task.pid)
    _ = Task.yield(task, 0)
    Process.demonitor(task.ref, [:flush])
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
