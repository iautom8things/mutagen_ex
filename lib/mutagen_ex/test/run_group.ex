defmodule MutagenEx.Test.RunGroup do
  @moduledoc false

  def start(destination) do
    spawn_link(fn -> forward_io(destination, MapSet.new()) end)
  end

  # Spawn tracing retains ancestry even when a test or module worker has
  # already exited by the time we enumerate the remaining group members.
  def track(group, runner) do
    session = :trace.session_create(:mutagen_site, group, [])
    1 = :trace.process(session, runner, true, [:procs, :set_on_spawn])
    {session, runner}
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

  def stop(group, action, processes, {session, _runner} = tracker) do
    restore_members(group, processes, Process.group_leader(), action, tracker)
    :ok
  after
    :trace.session_destroy(session)
    send(group, :stop)
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
    candidates = members(group)
    owned = if action == :reap, do: descendants(group, tracker), else: MapSet.new()

    kill =
      for pid <- candidates,
          not restore_or_reap(pid, processes, destination, owned) do
        pid
      end

    if kill != [] do
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

  defp descendants(group, {session, runner}) do
    delivered = :trace.delivered(session, :all)

    receive do
      {:trace_delivered, :all, ^delivered} -> :ok
    end

    ref = make_ref()
    send(group, {:descendants, self(), ref})

    receive do
      {^ref, descendants} -> MapSet.put(descendants, runner)
    end
  end

  defp restore_or_reap(pid, processes, fallback, owned) do
    if not Map.has_key?(processes, pid) and MapSet.member?(owned, pid) do
      false
    else
      restore_leader(pid, previous_leader(pid, processes, fallback), fallback)
      true
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

  defp forward_io(destination, descendants) do
    receive do
      {:io_request, _, _, _} = request ->
        send(destination, request)
        forward_io(destination, descendants)

      {:trace, _, :spawn, child, _} ->
        forward_io(destination, MapSet.put(descendants, child))

      {:descendants, caller, ref} ->
        send(caller, {ref, descendants})
        forward_io(destination, descendants)

      :stop ->
        :ok

      _trace ->
        forward_io(destination, descendants)
    end
  end
end
