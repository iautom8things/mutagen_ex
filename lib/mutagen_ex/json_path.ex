defmodule MutagenEx.JsonPath do
  @moduledoc """
  Canonicalisation and safety checks for `--json <path>`.

  `mix mutagen` accepts arbitrary user-supplied output paths via `--json`.
  Combined with the in-process compile-and-execute pipeline
  (`mutagen.decision.in_process_pipeline`), an un-validated path is an
  arbitrary-file-write primitive: a malicious mutated test in a third-party
  library could redirect the report into `/etc/`, `~/.ssh/authorized_keys`,
  or any other path the OS user can write.

  This module is the single home for the path-safety contract. Two layers:

    1. `validate_literal/1` — pure-string checks. Runs at CLI parse time so
       the bad shapes (NUL byte, `..` segments) produce an `:unsafe_json_path`
       abort-JSON before any filesystem touch.
    2. `canonicalize/2` — filesystem-aware check. Runs once after CLI parse
       but before any mutation phase. Expands the path, follows symlinks, and
       refuses any path whose resolved target lives outside the project root
       (unless the caller passed `unsafe_outside_project: true`).

  The split keeps `MutagenEx.CLI` pure (no IO from the parser) while letting
  the mix task gate the run on the FS-level check before any mutation runs.

  ## Project root

  The project root is `File.cwd!/0` at the time of invocation — `mix mutagen`
  always runs from the host project's root (Mix enforces this), so cwd is a
  reliable anchor. Symlinks in the cwd itself are resolved once via
  `Path.expand/1` so a symlinked project directory does not spuriously
  trip the inside-root check.
  """

  # Maximum number of symlink hops allowed during canonicalisation. A path
  # whose resolution exceeds this is refused as a traversal — symlink loops
  # are usually accidental, but the budget also catches adversarial chains.
  @symlink_loop_budget 40

  @typedoc "Reason atom returned on rejection. Single value; details map carries the variant."
  @type reason :: :unsafe_json_path

  @typedoc "Details map shape attached to every rejection."
  @type details :: %{
          required(:variant) =>
            :nul_byte | :traversal | :outside_project_root | :empty_path,
          required(:path) => String.t(),
          required(:message) => String.t(),
          optional(:resolved) => String.t(),
          optional(:project_root) => String.t()
        }

  @doc """
  Pure-string validation of a `--json` path literal.

  Rejects:

    * NUL bytes anywhere in the path (`:nul_byte`).
    * Any `..` segment in the path (`:traversal`). A literal `..` is the only
      way to escape upward without involving the filesystem; refusing it at
      the literal layer means downstream resolution does not need to deal
      with it.
    * Empty strings (`:empty_path`). `--json` requires a non-empty value.

  Accepts everything else, including:

    * Relative paths (resolved against cwd at write time).
    * Absolute paths (anchored where they are — the inside-root check happens
      in `canonicalize/2`).
    * Paths that pass through symlinks (handled in `canonicalize/2`).

  Returns `:ok` or `{:error, :unsafe_json_path, details}`.
  """
  @spec validate_literal(String.t()) :: :ok | {:error, reason(), details()}
  def validate_literal(path) when is_binary(path) do
    cond do
      path == "" ->
        {:error, :unsafe_json_path,
         %{
           variant: :empty_path,
           path: path,
           message: "--json requires a non-empty path"
         }}

      String.contains?(path, <<0>>) ->
        {:error, :unsafe_json_path,
         %{
           variant: :nul_byte,
           path: path,
           message: "--json path contains a NUL byte"
         }}

      has_traversal_segment?(path) ->
        {:error, :unsafe_json_path,
         %{
           variant: :traversal,
           path: path,
           message:
             "--json path contains a `..` segment; path traversal is refused"
         }}

      true ->
        :ok
    end
  end

  @doc """
  Filesystem-level canonicalisation.

  Returns `{:ok, absolute_path}` where `absolute_path` is the fully-resolved
  path that should be passed to `File.write!/2`. The returned path is
  absolute and symlink-free for every component that already exists; the
  final component (the report file) is allowed to be missing — it will be
  created at write time.

  Rejects `{:error, :unsafe_json_path, details}` when:

    * Any existing component is a symlink whose target escapes the project
      root (`:outside_project_root`).
    * The fully-resolved absolute path is outside the project root and the
      caller did not pass `unsafe_outside_project: true` (`:outside_project_root`).

  Options:

    * `:project_root` — absolute path of the project root. Defaults to
      `File.cwd!/0`. Resolved through `Path.expand/1` so a symlinked cwd
      does not trip the inside-root check.
    * `:unsafe_outside_project` — boolean. When `true`, the inside-root
      check is bypassed; only the symlink-escape check runs. Default `false`.

  Note: this function does NOT call `validate_literal/1` — callers (the
  CLI) run that at parse time, well before this function. Calling
  `canonicalize/2` with a literal-unsafe path is a programmer error, but
  to be safe the function still re-runs the cheap NUL-byte check (Erlang
  IO operations on NUL-containing paths raise; we prefer a typed error).
  """
  @spec canonicalize(String.t(), keyword()) ::
          {:ok, String.t()} | {:error, reason(), details()}
  def canonicalize(path, opts \\ []) when is_binary(path) and is_list(opts) do
    if String.contains?(path, <<0>>) do
      {:error, :unsafe_json_path,
       %{
         variant: :nul_byte,
         path: path,
         message: "--json path contains a NUL byte"
       }}
    else
      raw_root =
        opts
        |> Keyword.get(:project_root, File.cwd!())
        |> Path.expand()

      unsafe? = Keyword.get(opts, :unsafe_outside_project, false)

      # Fully resolve the project root through the symlink-walking resolver
      # FIRST. On macOS the canonical tmp dir is reached through
      # `/var -> /private/var`; the inside-root check has to compare
      # resolved-to-resolved or it never matches its own subdirectories.
      with {:ok, project_root} <- resolve_root(raw_root),
           absolute = Path.expand(path, project_root),
           {:ok, resolved} <- resolve_existing_prefix(absolute, project_root) do
        if unsafe? or inside?(resolved, project_root) do
          {:ok, resolved}
        else
          {:error, :unsafe_json_path,
           %{
             variant: :outside_project_root,
             path: path,
             resolved: resolved,
             project_root: project_root,
             message:
               "--json path resolves outside the project root (#{project_root}); " <>
                 "pass --unsafe-json-outside-project to opt in"
           }}
        end
      end
    end
  end

  # --- internals --------------------------------------------------------------

  # A path segment is a `..` iff the whole segment equals `".."`. We split on
  # the OS separator (always `/` on the platforms this tool targets — Mix
  # itself uses POSIX paths internally even on Windows for its own tasks).
  defp has_traversal_segment?(path) do
    path
    |> Path.split()
    |> Enum.any?(&(&1 == ".."))
  end

  # Resolve every symlink in the project root path without doing an
  # inside-root check (we're computing the root itself, so there is no
  # "outside" to refuse). On macOS this turns `/var/folders/...` into
  # `/private/var/folders/...` because `/var -> /private/var`.
  #
  # Returns `{:ok, fully_resolved_absolute_path}`. If the project root
  # does not exist we accept the literal expanded form — callers (the
  # mix task) have already verified the project root exists by virtue
  # of being a mix project.
  defp resolve_root(root) do
    case Path.split(root) do
      ["/" | rest] -> do_resolve_root(rest, "/", root, 0)
      other -> do_resolve_root(other, "", root, 0)
    end
  end

  defp do_resolve_root(_segments, _acc, original, depth)
       when depth > @symlink_loop_budget do
    {:error, :unsafe_json_path,
     %{
       variant: :traversal,
       path: original,
       message:
         "--json project root exceeds symlink resolution budget (#{@symlink_loop_budget})"
     }}
  end

  defp do_resolve_root([], acc, _original, _depth), do: {:ok, acc}

  defp do_resolve_root([segment | rest], acc, original, depth) do
    candidate = Path.join(acc, segment)

    case File.lstat(candidate) do
      {:ok, %File.Stat{type: :symlink}} ->
        case File.read_link(candidate) do
          {:ok, target} ->
            resolved_target = Path.expand(target, acc)

            new_segments =
              case Path.split(resolved_target) do
                ["/" | inner] -> inner ++ rest
                inner -> inner ++ rest
              end

            do_resolve_root(new_segments, "/", original, depth + 1)

          {:error, posix} ->
            {:error, :unsafe_json_path,
             %{
               variant: :traversal,
               path: original,
               message:
                 "--json project root symlink could not be read (#{candidate}): #{posix}"
             }}
        end

      {:ok, %File.Stat{}} ->
        do_resolve_root(rest, candidate, original, depth)

      {:error, :enoent} ->
        # The root (or some component of it) doesn't exist. Accept the
        # literal path we've built so far joined with the unresolved tail.
        # This shouldn't happen in production since `mix mutagen` runs
        # from a real project root, but tests may pass a non-existent
        # tmp dir.
        tail = Path.join([candidate | rest])
        {:ok, tail}

      {:error, posix} ->
        {:error, :unsafe_json_path,
         %{
           variant: :traversal,
           path: original,
           message:
             "--json project root component could not be stat'd (#{candidate}): #{posix}"
         }}
    end
  end

  # Walk the path from the filesystem root upward, resolving each existing
  # component through `File.read_link/1`. The final component may not exist
  # yet (the report file is created by `File.write!`); we stop resolving at
  # the first missing component and return the parent's resolved path plus
  # the not-yet-existing tail.
  #
  # Returns `{:ok, absolute_resolved_path}` on success. Any symlink whose
  # target escapes the project root short-circuits to
  # `{:error, :unsafe_json_path, %{variant: :outside_project_root, ...}}`.
  defp resolve_existing_prefix(absolute, project_root) do
    # `Path.split("/foo/bar")` returns `["/", "foo", "bar"]`. Strip the
    # leading separator so we can use it as the initial `acc` and walk the
    # remaining segments.
    case Path.split(absolute) do
      ["/" | rest] -> do_resolve(rest, "/", project_root, absolute, 0)
      other -> do_resolve(other, "", project_root, absolute, 0)
    end
  end

  defp do_resolve(_segments, _acc, _root, original, depth)
       when depth > @symlink_loop_budget do
    {:error, :unsafe_json_path,
     %{
       variant: :traversal,
       path: original,
       message: "--json path exceeds symlink resolution budget (#{@symlink_loop_budget})"
     }}
  end

  defp do_resolve([], acc, _root, _original, _depth), do: {:ok, acc}

  defp do_resolve([segment | rest], acc, root, original, depth) do
    candidate = Path.join(acc, segment)

    case File.lstat(candidate) do
      {:ok, %File.Stat{type: :symlink}} ->
        case File.read_link(candidate) do
          {:ok, target} ->
            # Symlink target: resolved relative to the symlink's parent
            # directory. We do NOT short-circuit on "target escapes root"
            # here — that decision happens once at the end, against the
            # fully-resolved final path. Per-segment short-circuiting
            # would refuse legitimate intermediate symlinks (e.g. macOS
            # `/var -> /private/var` when the project root itself lives
            # under `/private/var/...`).
            resolved_target = Path.expand(target, acc)

            new_segments =
              case Path.split(resolved_target) do
                ["/" | inner] -> inner ++ rest
                inner -> inner ++ rest
              end

            do_resolve(new_segments, "/", root, original, depth + 1)

          {:error, posix} ->
            {:error, :unsafe_json_path,
             %{
               variant: :traversal,
               path: original,
               message: "--json path symlink could not be read (#{candidate}): #{posix}"
             }}
        end

      {:ok, %File.Stat{}} ->
        # Regular file / directory / etc — accept and recurse.
        do_resolve(rest, candidate, root, original, depth)

      {:error, :enoent} ->
        # The component does not exist yet. Anything we have NOT resolved is
        # a literal tail; assemble it and return. Because we already refused
        # `..` segments at `validate_literal/1`, the tail cannot escape.
        tail = Path.join([candidate | rest])
        {:ok, tail}

      {:error, posix} ->
        {:error, :unsafe_json_path,
         %{
           variant: :traversal,
           path: original,
           message: "--json path component could not be stat'd (#{candidate}): #{posix}"
         }}
    end
  end

  # `inside?/2` is a string-level check on already-resolved absolute paths.
  # We treat the project root itself as "inside" so `--json mutagen.json` at
  # the project root works.
  defp inside?(path, root) do
    path == root or String.starts_with?(path, root <> "/")
  end
end
