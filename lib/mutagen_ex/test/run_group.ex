defmodule MutagenEx.Test.RunGroup do
  @moduledoc false

  def start(destination) do
    spawn_link(fn -> forward_io(destination) end)
  end

  def stop(group, :reap) do
    reap(group)
    send(group, :stop)
    :ok
  end

  def stop(group, {:release, destination}) do
    for pid <- members(group) do
      if Process.alive?(pid), do: restore_leader(pid, destination)
    end

    send(group, :stop)
    :ok
  end

  defp restore_leader(pid, destination) do
    Process.group_leader(pid, destination)
  rescue
    ArgumentError -> :ok
  end

  defp reap(group) do
    case members(group) do
      [] ->
        :ok

      members ->
        monitors = Enum.map(members, &Process.monitor/1)
        Enum.each(members, &Process.exit(&1, :kill))

        for monitor <- monitors do
          receive do
            {:DOWN, ^monitor, :process, _, _} -> :ok
          end
        end

        reap(group)
    end
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
