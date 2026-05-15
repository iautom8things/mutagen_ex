defmodule MutagenEx.Progress do
  @moduledoc """
  Human-readable per-site progress feedback written to stderr.

  Contract: `mutagen.mutation_pipeline.r15` (default-on-TTY, suppressed
  with `--no-progress`).

  `Mix.Tasks.Mutagen` attaches a `:telemetry` handler over the
  `[:mutagen_ex, :site, :stop]` event when progress is enabled, and that
  handler invokes `report/3` here. The handler is detached when the run
  ends (or aborts).

  Output format:

      [12/345] killed   path/to/file.ex:42 :arith
      [13/345] survived path/to/file.ex:43 :arith
      [14/345] timeout  path/to/file.ex:51 :case_drop

  - Lines are written to stderr; consumers redirect stdout (NDJSON or
    the final JSON document) without losing the progress feed.
  - The status column is left-padded to a stable width so the eye
    tracks the file column.
  - No carriage-return / cursor magic — `mix mutagen`'s consumers run
    under CI buffered I/O where re-paint tricks are a no-op anyway.
  """

  @doc """
  Decide whether to emit progress under the given `mode`.

  `mode` shapes:
    * `:on`   — always emit (used by `--progress`-like overrides).
    * `:off`  — never emit (set by `--no-progress`).
    * `:auto` — emit only when stderr is connected to a terminal.

  The TTY check uses `:io.getopts/1` against the `:stderr` device.
  Returns a boolean.
  """
  @spec enabled?(:auto | :on | :off) :: boolean()
  def enabled?(:on), do: true
  def enabled?(:off), do: false

  def enabled?(:auto) do
    case :io.getopts(:standard_error) do
      opts when is_list(opts) ->
        # `:terminal` is the documented key; some I/O backends omit it,
        # in which case we conservatively report `false` (no TTY).
        Keyword.get(opts, :terminal) == true

      _ ->
        false
    end
  end

  @doc """
  Emit a single progress line for a completed site.

  `meta` is the telemetry `.stop` metadata for `[:mutagen_ex, :site,
  :stop]`. Only `:site_id`, `:file`, `:line`, `:mutator`, `:status`,
  `:index`, and `:total` are read.
  """
  @spec report(map(), IO.device()) :: :ok
  def report(meta, device \\ :stderr) do
    line =
      [
        "[",
        to_string(Map.get(meta, :index, 0)),
        "/",
        to_string(Map.get(meta, :total, 0)),
        "] ",
        pad_status(Map.get(meta, :status, :unknown)),
        " ",
        to_string(Map.get(meta, :file, "")),
        ":",
        to_string(Map.get(meta, :line, 0)),
        " ",
        inspect(Map.get(meta, :mutator, :unknown)),
        "\n"
      ]

    IO.write(device, line)
  end

  defp pad_status(status) when is_atom(status) do
    str = Atom.to_string(status)
    # Longest status string is "compile_error" (13 chars). Pad to that
    # width so the file column aligns.
    String.pad_trailing(str, 13)
  end

  defp pad_status(other), do: String.pad_trailing(to_string(other), 13)
end
