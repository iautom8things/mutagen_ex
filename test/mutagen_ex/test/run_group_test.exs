defmodule MutagenEx.Test.RunGroupTest do
  use ExUnit.Case, async: false

  alias MutagenEx.MutationRunner.MutationLoop
  alias MutagenEx.Test.RunGroup

  defmodule SpawningExUnit do
    @moduledoc false
    # Starts an unlinked worker, as ExUnit's runner does, then returns or
    # blocks past the site deadline.
    def configure(_opts), do: :ok

    def run do
      {owner, block?} = :persistent_term.get({MutagenEx.Test.RunGroupTest, :site})
      worker = spawn(fn -> Process.sleep(:infinity) end)
      send(owner, {:worker, worker})
      if is_function(block?, 0), do: block?.()
      if block? == true, do: Process.sleep(:infinity)
      %{total: 1, failures: 0, excluded: 0, skipped: 0}
    end
  end

  defmodule NoopServer do
    @moduledoc false
    # Keeps the timeout path away from the ExUnit.Server queues of this mix test run.
    def add_module(_module, _config), do: :ok
    def discard_pending_modules, do: :ok
  end

  setup do
    on_exit(fn -> :persistent_term.erase({__MODULE__, :site}) end)
  end

  describe "per-site process group (mutagen.mutation_pipeline.s26)" do
    @describetag spec: "mutagen.mutation_pipeline.r22"

    test "a timed-out site's unlinked workers are dead when MutationLoop.run/1 returns" do
      :persistent_term.put({__MODULE__, :site}, {self(), true})

      assert {:timeout, _meta} = MutationLoop.run(site_input())
      assert_received {:worker, worker}
      refute Process.alive?(worker)
    end

    test "a completed site's surviving workers get the caller's group leader back" do
      :persistent_term.put({__MODULE__, :site}, {self(), false})

      assert {:completed, %{total: 1}, _meta} = MutationLoop.run(site_input())
      assert_received {:worker, worker}
      on_exit(fn -> Process.exit(worker, :kill) end)

      assert Process.alive?(worker)
      assert Process.info(worker, :group_leader) == {:group_leader, Process.group_leader()}
    end

    test "a timed-out worker blocked inside capture_io is reaped" do
      caller = self()

      :persistent_term.put(
        {__MODULE__, :site},
        {caller,
         fn ->
           spawn(fn ->
             ExUnit.CaptureIO.capture_io(fn ->
               send(caller, {:capturing, self(), Process.group_leader()})
               Process.sleep(:infinity)
             end)
           end)

           Process.sleep(:infinity)
         end}
      )

      assert {:timeout, _meta} = MutationLoop.run(site_input())
      assert_received {:capturing, worker, capture_device}
      on_exit(fn -> Enum.each([worker, capture_device], &Process.exit(&1, :kill)) end)
      refute Process.alive?(worker)
    end

    test "the group forwards member I/O and reaps processes its members spawn" do
      {:ok, device} = StringIO.open("")
      group = RunGroup.start(device)
      parent = self()

      member =
        spawn(fn ->
          receive do
            :start -> :ok
          end

          Process.group_leader(self(), group)
          IO.write("forwarded")
          send(parent, {:child, spawn(fn -> Process.sleep(:infinity) end)})
          Process.sleep(:infinity)
        end)

      tracker = RunGroup.track(member)
      send(member, :start)
      assert_receive {:child, child}
      assert StringIO.contents(device) == {"", "forwarded"}
      assert :ok = RunGroup.stop(group, :reap, %{}, tracker)
      refute Process.alive?(member)
      refute Process.alive?(child)
    end
  end

  @tag spec: "mutagen.mutation_pipeline.r34"
  test "reaps a child that changed its group leader before the test group died" do
    parent = self()
    destination = Process.group_leader()

    assert {:exit, {:run_group_exited, :killed}} =
             RunGroup.with_deadline(to_timeout(second: 2), fn ->
               worker = self()

               child =
                 spawn(fn ->
                   Process.group_leader(self(), destination)
                   send(worker, :outside_group)
                   Process.sleep(:infinity)
                 end)

               receive do
                 :outside_group ->
                   send(parent, {:child, child})
                   Process.exit(Process.group_leader(), :kill)
                   Process.sleep(:infinity)
               end
             end)

    assert_received {:child, child}
    refute Process.alive?(child)
  end

  @tag spec: "mutagen.mutation_pipeline.r26"
  test "stop waits for the group to exit and an immediate second stop returns" do
    group = RunGroup.start(Process.group_leader())
    runner = spawn(fn -> Process.sleep(:infinity) end)
    on_exit(fn -> Process.exit(runner, :kill) end)
    tracker = RunGroup.track(runner)
    session = :trace.session_create(:run_group_stop_test, self(), [])

    task =
      Task.async(fn ->
        receive do
          :stop_group -> RunGroup.stop(group, :release, %{}, tracker)
        end
      end)

    assert :erlang.suspend_process(group)

    try do
      assert :trace.process(session, task.pid, true, [:send]) == 1
      send(task.pid, :stop_group)
      task_pid = task.pid
      assert_receive {:trace, ^task_pid, :send, :stop, ^group}, to_timeout(second: 1)
      refute Task.yield(task, to_timeout(millisecond: 100))
    after
      :erlang.resume_process(group)
      :trace.session_destroy(session)
    end

    assert :ok = Task.await(task)
    refute Process.alive?(group)
    assert :ok = RunGroup.stop(group, :reap, %{}, tracker)
  end

  @tag spec: "mutagen.mutation_pipeline.r23"
  test "repeated timeouts restore a reassigned server without consuming supervisor restarts" do
    server_name = MutagenEx.Test.RunGroupFixtureServer

    supervisor =
      start_supervised!(%{
        id: :fixture_supervisor,
        start:
          {Supervisor, :start_link,
           [[{Agent, fn -> :ok end}], [strategy: :one_for_one, max_restarts: 1]]}
      })

    [{_, server, _, _}] = Supervisor.which_children(supervisor)
    Process.register(server, server_name)
    {:group_leader, original} = Process.info(server, :group_leader)

    :persistent_term.put(
      {__MODULE__, :site},
      {self(),
       fn ->
         Process.group_leader(Process.whereis(server_name), Process.group_leader())
         Process.sleep(:infinity)
       end}
    )

    for _ <- 1..3 do
      assert {:timeout, %{host_warnings: []}} = MutationLoop.run(%{site_input() | timeout_ms: 80})
      assert Process.whereis(server_name) == server
      assert Process.info(server, :group_leader) == {:group_leader, original}
      assert Process.alive?(supervisor)
    end
  end

  @tag spec: "mutagen.mutation_pipeline.r23"
  test "reports a pre-existing registered process that dies during a site" do
    name = MutagenEx.Test.RunGroupKilledServer
    server = spawn(fn -> Process.sleep(:infinity) end)
    Process.register(server, name)
    ref = Process.monitor(server)

    :persistent_term.put(
      {__MODULE__, :site},
      {self(),
       fn ->
         Process.exit(server, :kill)
         Process.sleep(:infinity)
       end}
    )

    assert {:timeout, %{host_warnings: warnings}} =
             MutationLoop.run(%{site_input() | timeout_ms: 80})

    assert {:host_process_died, Atom.to_string(name)} in warnings
    assert_received {:DOWN, ^ref, :process, ^server, :killed}
  end

  defmodule FixtureApplication do
    use Application

    @impl Application
    def start(_type, _args), do: Supervisor.start_link([], strategy: :one_for_one)
  end

  @tag spec: "mutagen.mutation_pipeline.r23"
  test "a timeout reports the loss of an unregistered root supervisor" do
    app = :mutagen_run_group_fixture
    assert :ok = :application.load({:application, app, [mod: {FixtureApplication, []}]})
    assert :ok = Application.start(app, :temporary)

    on_exit(fn ->
      Application.stop(app)
      Application.unload(app)
    end)

    master = :application_controller.get_master(app)
    {root, _} = :application_master.get_child(master)
    assert Process.info(root, :registered_name) == {:registered_name, []}

    :persistent_term.put(
      {__MODULE__, :site},
      {self(),
       fn ->
         Process.exit(root, :kill)
         Process.sleep(:infinity)
       end}
    )

    assert {:timeout, %{host_warnings: warnings}} =
             MutationLoop.run(%{site_input() | timeout_ms: 100})

    assert {:host_supervisor_changed, Atom.to_string(app)} in warnings
  end

  @tag spec: "mutagen.mutation_pipeline.r24"
  test "a child spawned by a reassigned host server survives a site timeout" do
    server = start_supervised!({Agent, fn -> :ok end})
    {:group_leader, original} = Process.info(server, :group_leader)
    owner = self()

    :persistent_term.put(
      {__MODULE__, :site},
      {owner,
       fn ->
         Process.group_leader(server, Process.group_leader())
         child = Agent.get(server, fn _ -> spawn_link(fn -> Process.sleep(:infinity) end) end)
         send(owner, {:host_child, child})
         Process.sleep(:infinity)
       end}
    )

    assert {:timeout, %{host_warnings: []}} = MutationLoop.run(%{site_input() | timeout_ms: 100})
    assert_received {:host_child, child}
    on_exit(fn -> if Process.alive?(child), do: Process.exit(child, :kill) end)
    assert Process.alive?(server)
    assert Process.alive?(child)
    assert Process.info(child, :group_leader) == {:group_leader, original}
  end

  @tag spec: "mutagen.mutation_pipeline.r24"
  test "restart under the same name does not report a host loss" do
    name = :mutagen_run_group_restart_fixture
    old = spawn(fn -> Process.sleep(:infinity) end)
    Process.register(old, name)
    owner = self()
    manager = start_supervised!({Agent, fn -> nil end})

    :persistent_term.put(
      {__MODULE__, :site},
      {owner,
       fn ->
         ref = Process.monitor(old)
         Process.exit(old, :kill)

         receive do
           {:DOWN, ^ref, :process, ^old, :killed} -> :ok
         end

         replacement =
           Agent.get(manager, fn _ -> spawn_link(fn -> Process.sleep(:infinity) end) end)

         Process.register(replacement, name)
         send(owner, {:restarted, replacement})
         Process.sleep(:infinity)
       end}
    )

    assert {:timeout, %{host_warnings: []}} = MutationLoop.run(%{site_input() | timeout_ms: 100})
    assert_received {:restarted, replacement}
    assert Process.whereis(name) == replacement
  end

  @tag spec: "mutagen.mutation_pipeline.r24"
  test "restoring a dead group leader falls back to the pipeline device" do
    dead = spawn(fn -> :ok end)
    ref = Process.monitor(dead)
    assert_receive {:DOWN, ^ref, :process, ^dead, _}
    fallback = Process.group_leader()
    pid = spawn(fn -> Process.sleep(:infinity) end)
    on_exit(fn -> Process.exit(pid, :kill) end)
    assert :ok = RunGroup.restore_leader(pid, dead, fallback)
    assert Process.info(pid, :group_leader) == {:group_leader, fallback}
  end

  defp site_input do
    %{
      test_modules: [],
      timeout_ms: 300,
      cancel_grace_ms: 0,
      ex_unit: SpawningExUnit,
      ex_unit_server: NoopServer
    }
  end
end
