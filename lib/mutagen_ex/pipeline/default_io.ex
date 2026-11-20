defmodule MutagenEx.Pipeline.DefaultIo do
  @moduledoc "Writes the report to the selected destination and halts with the pipeline's exit code."

  @behaviour MutagenEx.Pipeline.IoFacade

  alias MutagenEx.{Config, JsonPath}

  @impl MutagenEx.Pipeline.IoFacade
  def emit(iodata, exit_code, config), do: emit(iodata, exit_code, config, fn -> :ok end)

  @doc false
  def emit(iodata, exit_code, config, cleanup) do
    write(iodata, config)
    cleanup.()
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

  @doc false
  def write_summary(iodata, %Config{} = config) do
    opts = [
      project_root: config.json_root,
      unsafe_outside_project: config.unsafe_json_outside_project
    ]

    write_report(config.summary_path, config.summary_requested, config.json_root, opts, iodata)
  end

  defp write_stdout(iodata) do
    IO.write(Process.get(:mutagen_report_device, Process.group_leader()), iodata)
  end

  @report_pipe_env "MUTAGEN_INTERNAL_REPORT_PIPE"

  # OTP's erlang:display/1 writes to fd 1 without going through :user.
  # Give the host VM a separate report descriptor before it starts.
  @doc false
  def report_pipe(argv, ebin) do
    case System.get_env(@report_pipe_env) do
      "4" ->
        System.delete_env(@report_pipe_env)
        File.open("/dev/fd/4", [:write, :binary, encoding: :utf8])

      _ ->
        launch_with_report_pipe(argv, ebin)
    end
  end

  defp launch_with_report_pipe(argv, ebin) do
    bin = :elixir |> :code.lib_dir() |> Path.join("../../bin") |> Path.expand()
    elixir = Path.join(bin, "elixir")
    mix = Path.join(bin, "mix")

    with true <- File.regular?(elixir) and File.regular?(mix) do
      # All variable inputs are positional arguments to a fixed shell command.
      command = [
        "-c",
        ~S|exec "$@" 1>&2|,
        "mutagen",
        elixir,
        "-pa",
        ebin,
        "-S",
        mix,
        "mutagen" | argv
      ]

      env = [{to_charlist(@report_pipe_env), ~c"4"}, {~c"MIX_ENV", Atom.to_charlist(Mix.env())}]

      # Relay raw chunks, including those that split a UTF-8 character.
      :ok = :io.setopts(:standard_io, encoding: :latin1)

      # :nouse_stdio leaves fd 0 alone and carries port output on fd 4.
      port =
        Port.open({:spawn_executable, "/bin/sh"}, [
          :binary,
          :exit_status,
          :nouse_stdio,
          args: command,
          env: env
        ])

      forward_report(port)
    else
      false -> {:error, :missing_mix_executable}
    end
  rescue
    error in ErlangError -> {:error, error.original}
  end

  defp forward_report(port) do
    receive do
      {^port, {:data, data}} ->
        IO.binwrite(:stdio, data)
        forward_report(port)

      {^port, {:exit_status, code}} ->
        System.halt(code)
    end
  end

  @doc false
  def with_report_device(report_device, fun) do
    original_leader = Process.group_leader()
    user = Process.whereis(:user)
    stderr = Process.whereis(:standard_error)
    proxy = route_device(user, stderr)
    Process.unregister(:user)
    Process.register(proxy, :user)
    Process.put(:mutagen_report_device, report_device)

    move_group(user, proxy)
    Process.group_leader(self(), proxy)

    try do
      fun.()
    after
      Process.delete(:mutagen_report_device)
      Process.unregister(:user)
      Process.register(user, :user)
      move_group(proxy, user)
      Process.group_leader(self(), original_leader)
      send(proxy, :stop)
    end
  end

  @doc false
  def route_device(user, stderr) do
    spawn_link(fn -> forward_requests(user, stderr) end)
  end

  defp forward_requests(user, stderr) do
    receive do
      {:io_request, from, reply, {:requests, requests}} ->
        proxy = self()

        spawn(fn ->
          result =
            Enum.reduce_while(requests, :ok, fn request, _ ->
              case :io.request(proxy, request) do
                {:error, _} = error -> {:halt, error}
                value -> {:cont, value}
              end
            end)

          send(from, {:io_reply, reply, result})
        end)

        forward_requests(user, stderr)

      {:io_request, from, reply, request} ->
        {device, request} = route_request(request, user, stderr)
        send(device, {:io_request, from, reply, request})
        forward_requests(user, stderr)

      :stop ->
        :ok
    end
  end

  defp route_request(request, user, stderr) when is_tuple(request) do
    case Tuple.to_list(request) do
      [operation, encoding, prompt | args]
      when operation in [:get_line, :get_chars, :get_until] ->
        IO.write(stderr, prompt)
        {user, List.to_tuple([operation, encoding, "" | args])}

      [operation | _] when operation in [:get_password, :get_geometry, :setopts] ->
        {user, request}

      _ ->
        {stderr, request}
    end
  end

  defp route_request(request, user, _) when request in [:getopts, :get_password],
    do: {user, request}

  defp route_request(request, _, stderr), do: {stderr, request}

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
