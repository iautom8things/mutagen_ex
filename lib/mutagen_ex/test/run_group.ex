defmodule MutagenEx.Test.RunGroup do
  @moduledoc false

  def start(destination), do: spawn_owned(&forward_io(destination, &1))

  defp spawn_owned(fun) do
    owner = self()
    spawn(fn -> fun.(Process.monitor(owner)) end)
  end

  def with_deadline(timeout, fun, on_success \\ :reap) do
    caller = self()
    ref = make_ref()
    host = snapshot()
    group = start(Process.group_leader())
    group_monitor = Process.monitor(group)

    {worker, monitor} =
      spawn_monitor(fn ->
        receive do
          ^ref ->
            Process.group_leader(self(), group)
            send(caller, {ref, fun.()})
        end
      end)

    tracker = track(worker)
    send(worker, ref)

    try do
      result =
        receive do
          {^ref, result} ->
            Process.demonitor(monitor, [:flush])

            if Process.alive?(group),
              do: {:ok, result},
              else: {:exit, {:run_group_exited, :noproc}}

          {:DOWN, ^monitor, :process, ^worker, reason} ->
            if Process.alive?(group),
              do: {:exit, reason},
              else: {:exit, {:run_group_exited, :noproc}}

          {:DOWN, ^group_monitor, :process, ^group, reason} ->
            cancel(worker, monitor, ref)
            {:exit, {:run_group_exited, reason}}
        after
          timeout ->
            cancel(worker, monitor, ref)
            :timeout
        end

      action = if match?({:ok, _}, result), do: on_success, else: :reap
      stop(group, action, host.processes, tracker)
      result
    after
      Process.demonitor(group_monitor, [:flush])
    end
  end

  defp cancel(worker, monitor, ref) do
    Process.exit(worker, :kill)

    receive do
      {:DOWN, ^monitor, :process, ^worker, _} -> :ok
    end

    receive do
      {^ref, _} -> :ok
    after
      0 -> :ok
    end
  end

  # Keep ancestry when a worker exits or the group leader dies before cleanup.
  def track(runner) do
    tracer = spawn_owned(&trace_spawns(MapSet.new(), &1))
    session = :trace.session_create(:mutagen_site, tracer, [])
    1 = :trace.process(session, runner, true, [:procs, :set_on_spawn])
    {session, tracer, runner}
  end

  def snapshot do
    processes =
      for pid <- Process.list(),
          info = Process.info(pid, [:group_leader, :registered_name]),
          into: %{} do
        name =
          case info[:registered_name] do
            name when is_atom(name) -> name
            _ -> nil
          end

        {pid, {info[:group_leader], name}}
      end

    %{processes: processes, applications: application_roots()}
  end

  def stop(group, action, processes, {session, tracer, _runner} = tracker) do
    if Process.alive?(tracer) do
      try do
        restore_members(group, processes, Process.group_leader(), action, tracker)
      after
        :trace.session_destroy(session)
        stop_process(tracer)
        stop_process(group)
      end
    end

    :ok
  end

  defp stop_process(pid) do
    monitor = Process.monitor(pid)
    send(pid, :stop)

    receive do
      {:DOWN, ^monitor, :process, ^pid, _} -> :ok
    end
  end

  def host_warnings(_snapshot, false), do: []

  def host_warnings(snapshot, true) do
    registered =
      for {_, {_, name}} <- snapshot.processes,
          name != nil,
          not live_registration?(name) do
        {:host_process_died, Atom.to_string(name)}
      end

    supervisors =
      case {snapshot.applications, application_roots()} do
        {{:ok, before}, {:ok, after_roots}} ->
          for {app, root} <- before,
              Map.get(after_roots, app) != root or not Process.alive?(root) do
            {:host_supervisor_changed, Atom.to_string(app)}
          end

        _ ->
          []
      end

    Enum.sort(registered ++ supervisors)
  end

  defp live_registration?(name) do
    case Process.whereis(name) do
      pid when is_pid(pid) -> Process.alive?(pid)
      _ -> false
    end
  end

  defp application_roots do
    MutagenEx.Runtime.with_deadline(100, fn ->
      for {app, _, _} <- Application.started_applications(),
          master = :application_controller.get_master(app),
          is_pid(master),
          {root, _} <- [:application_master.get_child(master)],
          is_pid(root),
          into: %{} do
        {app, root}
      end
    end)
  end

  defp restore_members(group, processes, destination, action, tracker) do
    owned = if action == :reap, do: descendants(tracker), else: MapSet.new()

    kill =
      MapSet.filter(owned, fn pid -> not Map.has_key?(processes, pid) and Process.alive?(pid) end)

    for pid <- members(group), not MapSet.member?(kill, pid) do
      restore_leader(pid, previous_leader(pid, processes, destination), destination)
    end

    if MapSet.size(kill) > 0 do
      monitors = Enum.map(kill, &Process.monitor/1)
      Enum.each(kill, &Process.exit(&1, :kill))

      for monitor <- monitors do
        receive do
          {:DOWN, ^monitor, :process, _, _} -> :ok
        end
      end

      restore_members(group, processes, destination, action, tracker)
    end
  end

  defp descendants({session, tracer, runner}) do
    delivered = :trace.delivered(session, :all)

    receive do
      {:trace_delivered, :all, ^delivered} -> :ok
    end

    ref = make_ref()
    send(tracer, {:descendants, self(), ref})

    receive do
      {^ref, descendants} -> MapSet.put(descendants, runner)
    end
  end

  defp previous_leader(pid, processes, fallback) do
    case Map.fetch(processes, pid) do
      {:ok, {leader, _}} ->
        leader

      :error ->
        case Process.info(pid, :parent) do
          {:parent, parent} when is_pid(parent) -> previous_leader(parent, processes, fallback)
          _ -> fallback
        end
    end
  end

  @doc false
  def restore_leader(pid, previous, fallback) do
    Process.group_leader(pid, previous)
    if not Process.alive?(previous), do: Process.group_leader(pid, fallback)
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp members(group) do
    for pid <- Process.list(),
        Process.info(pid, :group_leader) == {:group_leader, group},
        do: pid
  end

  defp forward_io(destination, owner) do
    receive do
      {:io_request, _, _, _} = request ->
        send(destination, request)
        forward_io(destination, owner)

      :stop ->
        :ok

      {:DOWN, ^owner, :process, _, _} ->
        :ok

      _ ->
        forward_io(destination, owner)
    end
  end

  defp trace_spawns(descendants, owner) do
    receive do
      {:trace, _, :spawn, child, _} ->
        trace_spawns(MapSet.put(descendants, child), owner)

      {:descendants, caller, ref} ->
        send(caller, {ref, descendants})
        trace_spawns(descendants, owner)

      :stop ->
        :ok

      {:DOWN, ^owner, :process, _, _} ->
        :ok

      _ ->
        trace_spawns(descendants, owner)
    end
  end
end
