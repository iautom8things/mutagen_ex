defmodule MutagenEx.Pipeline.DefaultIo do
  @moduledoc "Writes the report to the selected destination and halts with the pipeline's exit code."

  @behaviour MutagenEx.Pipeline.IoFacade

  alias MutagenEx.{Config, JsonPath}
  alias MutagenEx.JsonReporter.Sanitizer

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
          Sanitizer.clean(
            "warning: json_write_failed (#{inspect(error)}); writing report to stdout"
          )
        )

        IO.write(document)
    end
  end

  def write(iodata, _config), do: IO.write(iodata)

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

      case File.write(temp, document, [:exclusive]) do
        :ok ->
          try do
            with :ok <- unchanged_path(path, requested, opts) do
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
