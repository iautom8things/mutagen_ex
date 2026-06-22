defmodule MutagenEx.Test.PathHelpers do
  @moduledoc """
  Shared path-resolution helpers for test files that need to predict the
  canonical absolute path the production canonicaliser will produce on a
  host whose tmp / etc / var paths are themselves symlinks (macOS).
  """

  @doc """
  Resolve every symlink in `path` using the same algorithm
  `MutagenEx.JsonPath.canonicalize/2` uses for its project root. Returns
  the fully-resolved absolute path.
  """
  def resolve_symlinks(path) do
    absolute = Path.expand(path)
    segments = Path.split(absolute)

    {head, rest} =
      case segments do
        ["/" | tail] -> {"/", tail}
        other -> {"", other}
      end

    walk(rest, head)
  end

  defp walk([], acc), do: acc

  defp walk([segment | rest], acc) do
    candidate = Path.join(acc, segment)

    case File.lstat(candidate) do
      {:ok, %File.Stat{type: :symlink}} ->
        {:ok, target} = File.read_link(candidate)
        resolved_target = Path.expand(target, acc)

        new_segments =
          case Path.split(resolved_target) do
            ["/" | inner] -> inner ++ rest
            inner -> inner ++ rest
          end

        walk(new_segments, "/")

      {:ok, _stat} ->
        walk(rest, candidate)

      {:error, :enoent} ->
        Path.join([candidate | rest])
    end
  end
end
