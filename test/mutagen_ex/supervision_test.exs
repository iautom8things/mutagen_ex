defmodule MutagenEx.SupervisionTest do
  @moduledoc """
  Five scenarios covering the supervision-tree contract for mutagen-wrd.18.

  Each scenario maps to a `.spec/specs/*.spec.md` stub by ID:

  - Scenario 1 — `mutagen.mutation_pipeline.s11` (covers r13: TaskSup + root
    supervisor boot).
  - Scenario 2 — `mutagen.mutation_pipeline.s12` (covers r14: start_child /
    terminate_child round-trip, architecture §7.1 verbatim).
  - Scenario 3 — `mutagen.mutation_pipeline.s12` extended (covers r14:
    `terminate_child` propagates `:shutdown` through the link tree).
  - Scenario 4 — `mutagen.coverage.s8` (covers r1 + r8: singleton-ownership
    rejection cites `MutagenEx.TaskSup`).
  - Scenario 5 — `mutagen.mutation_pipeline.s13` (covers r14 + r7: snapshot
    delta is empty for `Process.registered/0`, `:ets.all/0`, and
    `:persistent_term.info().count` after a `:timeout` outcome reaps the
    linked descendants via `terminate_child/2`).

  Marked `async: false` because:
    - We mutate the BEAM-wide `:cover_server` registration in Scenario 4.
    - We exercise the singleton `MutagenEx.TaskSup` directly across scenarios.
    - Snapshot deltas (Scenario 5) are non-deterministic under parallelism.
  """

  use ExUnit.Case, async: false

  alias MutagenEx.MutationRunner.MutationLoop
  alias MutagenEx.TestSelector.TestFilter

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defmodule Helper do
    @moduledoc """
    Synthetic linked-descendant for scenarios 3 and 5.

    Traps exits and sleeps for 20 ms in `terminate/2`. The trap exercises
    the cooperative-shutdown path; the 20 ms sleep gives the test a
    bounded poll window to assert the registered name is released after
    the `:DOWN` arrives.
    """

    use GenServer

    def start_link(name) do
      GenServer.start_link(__MODULE__, :ok, name: name)
    end

    @impl GenServer
    def init(:ok) do
      Process.flag(:trap_exit, true)
      {:ok, %{}}
    end

    @impl GenServer
    def terminate(_reason, _state) do
      Process.sleep(20)
      :ok
    end
  end

  # Poll-wait for a registered name to be released (cleared by the BEAM
  # after the owning process terminates). Avoids the racy
  # `refute Process.alive?` idiom; cf. plan TR-2.
  defp wait_for_unregistered!(name, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_unregistered!(name, deadline)
  end

  defp do_wait_unregistered!(name, deadline) do
    case Process.whereis(name) do
      nil ->
        :ok

      pid when is_pid(pid) ->
        now = System.monotonic_time(:millisecond)

        if now >= deadline do
          flunk(
            "registered name #{inspect(name)} was not released within timeout " <>
              "(still resolves to #{inspect(pid)})"
          )
        else
          Process.sleep(10)
          do_wait_unregistered!(name, deadline)
        end
    end
  end

  # Wait for a {:DOWN, _, :process, _, _} message for the given monitor
  # ref within `timeout_ms`. Returns the exit reason on receipt; flunks
  # on timeout.
  defp assert_down!(ref, timeout_ms) do
    receive do
      {:DOWN, ^ref, :process, _pid, reason} -> reason
    after
      timeout_ms ->
        flunk(
          ":DOWN was not received for ref #{inspect(ref)} within " <>
            "#{timeout_ms} ms"
        )
    end
  end

  # ---------------------------------------------------------------------------
  # Setup: per-test cleanup of any task left under MutagenEx.TaskSup.
  # ---------------------------------------------------------------------------

  setup do
    on_exit(fn ->
      # `Task.Supervisor.children/1` returns `[pid()]` — NOT 4-tuples.
      # Terminate any children that survived a misbehaving scenario so
      # the next test starts from a known state.
      case Process.whereis(MutagenEx.TaskSup) do
        nil ->
          :ok

        _sup_pid ->
          MutagenEx.TaskSup
          |> Task.Supervisor.children()
          |> Enum.each(fn pid ->
            _ = Task.Supervisor.terminate_child(MutagenEx.TaskSup, pid)
          end)
      end
    end)

    :ok
  end

  # ---------------------------------------------------------------------------
  # Scenario 1 — Application + TaskSup boots.
  # Spec: mutagen.mutation_pipeline.s11 ↔ r13
  # ---------------------------------------------------------------------------

  describe "scenario 1 — Application + TaskSup boots (s11 ↔ r13)" do
    test "ensure_all_started/1 returns :ok and named supervisors are alive" do
      assert {:ok, _started} = Application.ensure_all_started(:mutagen_ex)
      assert is_pid(Process.whereis(MutagenEx.TaskSup))
      assert is_pid(Process.whereis(MutagenEx.Supervisor))
    end
  end

  # ---------------------------------------------------------------------------
  # Scenario 2 — start_child / terminate_child round-trip.
  # Spec: mutagen.mutation_pipeline.s12 ↔ r14 (architecture §7.1 verbatim)
  # ---------------------------------------------------------------------------

  describe "scenario 2 — start_child / terminate_child round-trip (s12 ↔ r14)" do
    test "Task.Supervisor.start_child + terminate_child clears the child" do
      parent = self()

      {:ok, child} =
        Task.Supervisor.start_child(MutagenEx.TaskSup, fn ->
          send(parent, {:child_pid, self()})
          Process.sleep(:infinity)
        end)

      assert_receive {:child_pid, ^child}, 1_000
      ref = Process.monitor(child)

      assert :ok = Task.Supervisor.terminate_child(MutagenEx.TaskSup, child)
      _reason = assert_down!(ref, 5_000)
    end
  end

  # ---------------------------------------------------------------------------
  # Scenario 3 — terminate_child propagates :shutdown through link tree.
  # Spec: mutagen.mutation_pipeline.s12 / s13 (extension on r14)
  # ---------------------------------------------------------------------------

  describe "scenario 3 — terminate_child propagates through link tree (s12/s13 ↔ r14)" do
    test "named trapping GenServer + unnamed worker both DOWN within window" do
      parent = self()
      helper_name = :"supervision_test_helper_s3_#{System.unique_integer([:positive])}"

      # `start_child/2` (not `async_nolink`) so the parent task is
      # ALSO a supervised child whose pid we can call
      # `Task.Supervisor.terminate_child/2` against directly.
      {:ok, task_pid} =
        Task.Supervisor.start_child(MutagenEx.TaskSup, fn ->
          {:ok, helper_pid} = Helper.start_link(helper_name)

          worker_pid =
            spawn_link(fn ->
              # Unnamed worker; no trap_exit. Should be reaped when the
              # parent task is terminated via the supervisor.
              Process.sleep(:infinity)
            end)

          send(parent, {:pids, self(), helper_pid, worker_pid})
          Process.sleep(:infinity)
        end)

      assert_receive {:pids, ^task_pid, helper_pid, worker_pid}, 1_000

      # Monitor all three BEFORE the kill — guarantees we observe the
      # :DOWN even if any of them die instantly.
      task_ref = Process.monitor(task_pid)
      helper_ref = Process.monitor(helper_pid)
      worker_ref = Process.monitor(worker_pid)

      assert :ok = Task.Supervisor.terminate_child(MutagenEx.TaskSup, task_pid)

      _ = assert_down!(task_ref, 5_000)
      _ = assert_down!(helper_ref, 5_000)
      _ = assert_down!(worker_ref, 5_000)

      # Helper.terminate/2 sleeps 20 ms; the registered name is released
      # only after that callback returns. Poll-wait gives a bounded
      # window without resorting to refute Process.alive?.
      wait_for_unregistered!(helper_name, 2_000)
    end
  end

  # ---------------------------------------------------------------------------
  # Scenario 4 — concurrent-caller rejection cites MutagenEx.TaskSup.
  # Spec: mutagen.coverage.s8 ↔ r1 / r8
  # ---------------------------------------------------------------------------

  describe "scenario 4 — concurrent-caller rejection (s8 ↔ r1/r8)" do
    # Registers a sentinel under :cover_server and unregisters whatever is
    # already there — under `mix test --cover` that would evict the
    # harness's cover server. Excluded in --cover mode via test_helper.exs.
    @describetag :cover_lifecycle
    test "cover_already_running message names MutagenEx.TaskSup as singleton owner" do
      # Register a sentinel pid as :cover_server to simulate an in-flight
      # MutagenEx mutation cycle (or any other competing cover session).
      # The sentinel just blocks; on_exit terminates and unregisters it.
      sentinel =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      # Defensive: in case :cover_server is somehow already registered
      # (e.g. from a previous test that didn't clean up), unregister it
      # before claiming the name ourselves.
      case Process.whereis(:cover_server) do
        nil -> :ok
        _pid -> Process.unregister(:cover_server)
      end

      true = Process.register(sentinel, :cover_server)

      on_exit(fn ->
        case Process.whereis(:cover_server) do
          ^sentinel ->
            Process.unregister(:cover_server)
            send(sentinel, :stop)

          _ ->
            :ok
        end
      end)

      input = %{
        seed: 0,
        in_scope_modules: [],
        test_filter: %TestFilter{include: [], exclude: [], files: []}
      }

      assert {:error, :cover_already_running, %{message: msg}} =
               MutagenEx.CoverageRunner.run(input)

      # TR-8: assert on the atom + concept substring only, NOT exact prose.
      assert msg =~ "MutagenEx.TaskSup"
    end
  end

  # ---------------------------------------------------------------------------
  # Scenario 5 — snapshot delta is empty on recursive-shutdown of a timeout.
  # Spec: mutagen.mutation_pipeline.s13 ↔ r14 / r7
  # ---------------------------------------------------------------------------

  defmodule SleepyExUnit do
    @moduledoc """
    `ex_unit` stub for scenario 5: spawn_links a named GenServer
    (`MutagenEx.SupervisionTest.Helper`) that traps exits, then blocks
    forever. The supervised task runs in a separate process whose
    process dictionary is NOT inherited from the caller, so the unique
    helper name is passed via `:persistent_term` (set before
    `MutationLoop.run/1` enters `take_snapshot`, so the entry counts
    in BOTH before- and after-snapshots and cancels out of the delta).

    Forces `Config.timeout_ms` to fire; the named child must be reaped
    by `terminate_child/2`'s recursive shutdown for the snapshot delta
    to remain zero.
    """

    def configure(_opts), do: :ok

    def run do
      name = :persistent_term.get({MutagenEx.SupervisionTest, :sleepy_helper_name})
      {:ok, _pid} = MutagenEx.SupervisionTest.Helper.start_link(name)
      Process.sleep(:infinity)
    end
  end

  defmodule NoopExUnitServer do
    @moduledoc false
    def add_module(_mod, _cfg), do: :ok
  end

  describe "scenario 5 — snapshot delta zero on recursive-shutdown (s13 ↔ r14/r7)" do
    test "MutationLoop.run timeout with linked named GenServer leaves delta empty" do
      helper_name = :"supervision_test_helper_s5_#{System.unique_integer([:positive])}"

      # The supervised task body cannot see this test's process
      # dictionary — pass the helper name through :persistent_term.
      # Set it BEFORE the first `take_snapshot/0` so the
      # persistent_term count is identical before and after and the
      # delta is honest.
      :persistent_term.put({__MODULE__, :sleepy_helper_name}, helper_name)
      on_exit(fn -> :persistent_term.erase({__MODULE__, :sleepy_helper_name}) end)

      input = %{
        test_modules: [],
        timeout_ms: 50,
        cancel_grace_ms: 0,
        ex_unit: SleepyExUnit,
        ex_unit_server: NoopExUnitServer
      }

      snapshot_before = MutationLoop.take_snapshot()
      outcome = MutationLoop.run(input)
      # Wait for the helper's `terminate/2` sleep to release the
      # registered name; the snapshot is BEAM-wide so we want a quiet
      # point.
      wait_for_unregistered!(helper_name, 2_000)
      snapshot_after = MutationLoop.take_snapshot()

      assert {:timeout, _meta} = outcome

      delta = MutationLoop.snapshot_delta(snapshot_before, snapshot_after)

      refute MutationLoop.snapshot_grew?(delta),
             "expected snapshot to NOT grow across a supervised-kill timeout " <>
               "but got delta=#{inspect(delta)} " <>
               "(before=#{inspect(snapshot_before)}, after=#{inspect(snapshot_after)})"
    end
  end
end
