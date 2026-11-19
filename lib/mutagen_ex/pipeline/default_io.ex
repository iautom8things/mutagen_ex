defmodule MutagenEx.Pipeline.DefaultIo do
  @moduledoc "Writes the report to the selected destination and halts with the pipeline's exit code."

  @behaviour MutagenEx.Pipeline.IoFacade

  alias MutagenEx.{Config, JsonPath}

  @impl MutagenEx.Pipeline.IoFacade
  def emit(iodata, exit_code, config) do
    write(iodata, config)
    System.halt(exit_code)
  end

  @doc false
  def write(iodata, %Config{json_path: path} = config) when is_binary(path) do
    buffered = if config.stream, do: Process.delete(:mutagen_stream_buffer) || [], else: []
    document = [buffered, iodata]
    root = config.json_root || File.cwd!()
    requested = config.json_requested || path
    opts = [project_root: root, unsafe_outside_project: config.unsafe_json_outside_project]

    case write_report(path, requested, root, opts, document) do
      :ok ->
        :ok

      error ->
        IO.puts(
          :stderr,
          "warning: json_write_failed (#{inspect(error)}); writing report to stdout"
        )

        write_stdout(document)
    end
  end

  def write(iodata, _config), do: write_stdout(iodata)

  defp write_stdout(iodata) do
    IO.write(Process.get(:mutagen_report_device, Process.group_leader()), iodata)
  end

  @doc false
  def with_report_device(fun) do
    stdout = Process.group_leader()
    user = Process.whereis(:user)
    stderr = Process.whereis(:standard_error)
    proxy = MutagenEx.Test.RunGroup.start(stderr)
    Process.unregister(:user)
    Process.register(proxy, :user)
    Process.put(:mutagen_report_device, stdout)

    move_group(user, proxy)
    Process.group_leader(self(), proxy)

    try do
      fun.()
    after
      Process.delete(:mutagen_report_device)
      Process.unregister(:user)
      Process.register(user, :user)
      move_group(proxy, user)
      Process.group_leader(self(), stdout)
      send(proxy, :stop)
    end
  end

  defp move_group(from, to) do
    for pid <- Process.list(),
        pid != to,
        Process.info(pid, :group_leader) == {:group_leader, from} do
      try do
        Process.group_leader(pid, to)
      rescue
        ArgumentError -> :ok
      end
    end
  end

  defp write_report(path, requested, root, opts, document) do
    parent = Path.dirname(path)

    with :ok <- unchanged_path(path, requested, opts),
         :ok <- ensure_parent(parent, root),
         :ok <- unchanged_path(path, requested, opts) do
      temp =
        Path.join(
          parent,
          ".mutagen-#{Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)}.tmp"
        )

      case File.open(temp, [:write, :binary, :exclusive]) do
        {:ok, io} ->
          try do
            with :ok <- write_private(io, temp, document),
                 :ok <- unchanged_path(path, requested, opts) do
              File.rename(temp, path)
            end
          after
            File.rm(temp)
          end

        {:error, _} = error ->
          error
      end
    end
  end

  defp write_private(io, temp, document) do
    result =
      with :ok <- File.chmod(temp, 0o600) do
        IO.binwrite(io, document)
      end

    close_result = File.close(io)
    with :ok <- result, do: close_result
  end

  defp unchanged_path(path, requested, opts) do
    case JsonPath.canonicalize(requested, opts) do
      {:ok, ^path} -> :ok
      {:ok, _} -> {:error, :json_path_changed}
      {:error, reason, _} -> {:error, reason}
    end
  end

  defp ensure_parent(parent, root) do
    case JsonPath.canonicalize(parent, project_root: root) do
      {:ok, ^parent} -> File.mkdir_p(parent)
      _ -> :ok
    end
  end
end
