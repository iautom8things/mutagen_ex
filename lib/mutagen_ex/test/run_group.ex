defmodule MutagenEx.Test.RunGroup do
  @moduledoc false

  def start(destination) do
    spawn_link(fn -> forward_io(destination) end)
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

  def stop(group, action, processes \\ %{}) do
    destination = Process.group_leader()
    restore_members(group, processes, destination, action)
    send(group, :stop)
    :ok
  end

  def host_warnings(snapshot, timed_out?) do
    registered =
      for {pid, {_, name}} <- snapshot.processes, name != nil, not Process.alive?(pid) do
        {:host_process_died, Atom.to_string(name)}
      end

    supervisors =
      if timed_out? do
        case snapshot.applications do
          {:ok, applications} ->
            for {app, master, root} <- applications,
                :application_controller.get_master(app) != master or not Process.alive?(root) do
              {:host_supervisor_changed, Atom.to_string(app)}
            end

          _ ->
            [{:host_supervisor_changed, "could not verify application supervisors"}]
        end
      else
        []
      end

    Enum.sort(registered ++ supervisors)
  end

  defp application_roots do
    MutagenEx.Runtime.with_deadline(100, fn ->
      for {app, _, _} <- Application.started_applications(),
          master = :application_controller.get_master(app),
          is_pid(master),
          {root, _} <- [:application_master.get_child(master)],
          is_pid(root) do
        {app, master, root}
      end
    end)
  end

  defp restore_members(group, processes, destination, action) do
    new_members =
      group
      |> members()
      |> Enum.reject(fn pid ->
        case Map.fetch(processes, pid) do
          {:ok, {previous, _name}} ->
            leader = if Process.alive?(previous), do: previous, else: destination
            restore_leader(pid, leader)
            true

          :error ->
            false
        end
      end)

    case {action, new_members} do
      {_, []} ->
        :ok

      {{:release, leader}, pids} ->
        Enum.each(pids, &restore_leader(&1, leader))

      {:reap, pids} ->
        monitors = Enum.map(pids, &Process.monitor/1)
        Enum.each(pids, &Process.exit(&1, :kill))

        for monitor <- monitors do
          receive do
            {:DOWN, ^monitor, :process, _, _} -> :ok
          end
        end

        restore_members(group, processes, destination, action)
    end
  end

  defp restore_leader(pid, destination) do
    Process.group_leader(pid, destination)
  rescue
    ArgumentError -> :ok
  end

  defp members(group) do
    for pid <- Process.list(),
        Process.info(pid, :group_leader) == {:group_leader, group},
        do: pid
  end

  defp forward_io(destination) do
    receive do
      {:io_request, _, _, _} = request ->
        send(destination, request)
        forward_io(destination)

      :stop ->
        :ok
    end
  end
end
