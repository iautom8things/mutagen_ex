defmodule MutagenEx.Pipeline.DefaultIo do
  @moduledoc """
  Default `MutagenEx.Pipeline.IoFacade` implementation — writes the
  final encoded document to stdout (or `Config.json_path`), then halts
  the BEAM with `exit_code`.

  Lifted out of `Mix.Tasks.Mutagen` (bw mutagen-wrd.33) so the `:io`
  dispatch slot can be a plain module atom rather than a `{module,
  function}` tuple. The behaviour is `MutagenEx.Pipeline.IoFacade`;
  the test seam swaps a non-halting capture module so the test VM
  stays alive past `emit/3`.

  When `--stream` is set together with `--json <path>` the streamer
  has accumulated per-site NDJSON lines in the calling process's
  dictionary under `:mutagen_stream_buffer`. We flush that buffer
  FIRST, then append the aggregate document — both go to the same
  file in a single `File.write!/2` so the file is created atomically
  (no partial-write race observable to a watcher tailing the file).
  """

  @behaviour MutagenEx.Pipeline.IoFacade

  alias MutagenEx.Config

  @impl MutagenEx.Pipeline.IoFacade
  @spec emit(iodata(), non_neg_integer(), Config.t() | nil) :: no_return()
  def emit(iodata, exit_code, config) do
    case config do
      %Config{json_path: nil, stream: true} ->
        # `--stream` without `--json`: NDJSON lines have already been
        # written incrementally to stdout via `:standard_io`. The
        # final aggregate document follows on the same stream so a
        # tailing consumer sees N+2 NDJSON values followed by the
        # multi-line aggregate.
        IO.write(iodata)

      %Config{json_path: nil} ->
        IO.write(iodata)

      %Config{json_path: path, stream: true} when is_binary(path) ->
        buffered = Process.get(:mutagen_stream_buffer, [])
        Process.delete(:mutagen_stream_buffer)
        File.write!(path, [buffered, iodata])

      %Config{json_path: path} when is_binary(path) ->
        File.write!(path, iodata)

      _ ->
        IO.write(iodata)
    end

    System.halt(exit_code)
  end
end
