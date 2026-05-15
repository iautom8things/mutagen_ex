defmodule MutagenEx.TestSupport.DiskSnapshot do
  @moduledoc """
  Disk-snapshot diffing helpers for the r11 / r7 "no disk writes" invariants
  (`mutagen.mutation_pipeline.r11`, `mutagen.coverage.r7`).

  ## Why this exists

  The original r11 / r7 tests hashed only `lib/**/*.ex`. That misses the
  surfaces the runner is most likely to touch by accident:

    * `_build/**` — compiled `.beam` and dep state. Any call into
      `Code.compile_file/1`, `Mix.Task.run("compile")`, or `:cover`
      auto-instrumentation can land bytes here.
    * `cover/**` — `:cover` writes coverage reports here if the user
      invoked `:cover.analyze/0` with on-disk output. The MutagenEx
      pipeline must not produce this directory.
    * `/tmp` — `System.tmp_dir!()` is a common stash. We can't hash all
      of `/tmp` (huge, shared, racy), so we enumerate the *names* of
      top-level entries and assert no new ones with a MutagenEx-attributable
      prefix appear.
    * Host project config (`mix.exs`, `mix.lock`, `.formatter.exs`) —
      these are the files a "while I'm here" mutation could most
      damagingly rewrite.

  ## Allowed writes (rationale)

  Two surfaces are intentionally NOT asserted against:

    * `_build/<env>/lib/<dep>/...` files written by Mix as a side
      effect of `mix test` re-checking dependency build state on entry
      to a test. Mix can touch these files (mtime bump, recompile
      state cache) outside MutagenEx's control. We snapshot `_build/**`
      *content* hashes, but only flag content drift on artifacts that
      can be traced to the runner (e.g. mutated module's .beam).
      Helper: `diff_build/2` returns the path list; the caller decides
      what to flag.

    * Files under `System.tmp_dir!()` whose names do not match the
      MutagenEx prefix. Tmp entries created by other processes during
      the test run are noise; we only assert that no entry whose name
      starts with `mutagen_ex_` or contains the runner's PID survives
      the test.

  This helper does NOT enforce policy — it returns structured diffs.
  Each test decides which categories are PASS / FAIL for its
  invariant. The r11 test in `mutation_runner_test.exs` and the r7
  test in `coverage_runner_test.exs` document their own allowed-write
  lists in test comments.

  ## API

    * `snapshot/1` — take a snapshot of the configured surfaces; returns
      an opaque term.
    * `diff/2` — diff two snapshots; returns
      `%{added: [...], modified: [...], removed: [...]}` per surface.
    * `host_config_files/0` — list of host config file paths checked.
    * `default_globs/0` — list of glob patterns snapshotted (lib + _build
      + cover).
  """

  @host_config_files [
    "mix.exs",
    "mix.lock",
    ".formatter.exs"
  ]

  @default_globs [
    "lib/**/*.ex",
    "lib/**/*.exs",
    "_build/**/*.beam",
    "_build/**/*.app",
    "cover/**/*"
  ]

  @doc "Files always checked for byte-identity (host project config)."
  def host_config_files, do: @host_config_files

  @doc "Glob patterns snapshotted by default."
  def default_globs, do: @default_globs

  @doc """
  Take a snapshot of:

    * Every file matching `default_globs/0`, by SHA-256.
    * Every host-config file (`host_config_files/0`) that exists, by
      SHA-256.
    * Top-level entries under `System.tmp_dir!()` (names only — listing,
      not hashing).

  Returns a map suitable for diffing with `diff/2`. Missing files
  (e.g. no `cover/` directory) are simply absent from the snapshot —
  this is normal and not an error.
  """
  def snapshot(opts \\ []) do
    globs = Keyword.get(opts, :globs, @default_globs)
    configs = Keyword.get(opts, :host_configs, @host_config_files)
    tmp_dir = Keyword.get(opts, :tmp_dir, safe_tmp_dir())

    %{
      files: hash_globs(globs) |> Map.merge(hash_host_configs(configs)),
      tmp_entries: list_tmp_entries(tmp_dir),
      tmp_dir: tmp_dir
    }
  end

  @doc """
  Diff two snapshots produced by `snapshot/1`.

  Returns:

      %{
        added:    [path, ...],          # in `post` but not in `pre`
        modified: [path, ...],          # hash changed between snapshots
        removed:  [path, ...],          # in `pre` but not in `post`
        tmp_added: [name, ...],         # /tmp entries newly visible post
        tmp_removed: [name, ...]        # /tmp entries gone post
      }

  Path lists are sorted for stable assertion messages.
  """
  def diff(pre, post) do
    pre_files = pre.files
    post_files = post.files

    pre_paths = Map.keys(pre_files) |> MapSet.new()
    post_paths = Map.keys(post_files) |> MapSet.new()

    added =
      MapSet.difference(post_paths, pre_paths)
      |> Enum.sort()

    removed =
      MapSet.difference(pre_paths, post_paths)
      |> Enum.sort()

    modified =
      MapSet.intersection(pre_paths, post_paths)
      |> Enum.filter(fn p -> Map.fetch!(pre_files, p) != Map.fetch!(post_files, p) end)
      |> Enum.sort()

    pre_tmp = MapSet.new(pre.tmp_entries)
    post_tmp = MapSet.new(post.tmp_entries)

    %{
      added: added,
      modified: modified,
      removed: removed,
      tmp_added: MapSet.difference(post_tmp, pre_tmp) |> Enum.sort(),
      tmp_removed: MapSet.difference(pre_tmp, post_tmp) |> Enum.sort()
    }
  end

  @doc """
  Filter a diff's `tmp_added` list to entries that match a MutagenEx-
  attributable prefix (default: `mutagen_ex`). Other entries are
  background noise from concurrent test runs or unrelated processes
  and are NOT a violation of r11 / r7.
  """
  def mutagen_attributable_tmp(diff, prefix \\ "mutagen_ex") do
    Enum.filter(diff.tmp_added, &String.starts_with?(&1, prefix))
  end

  # ---- internal --------------------------------------------------------------

  defp hash_globs(globs) do
    globs
    |> Enum.flat_map(&Path.wildcard/1)
    |> Enum.uniq()
    |> Enum.filter(&File.regular?/1)
    |> Enum.into(%{}, fn path ->
      {path, :crypto.hash(:sha256, File.read!(path))}
    end)
  end

  defp hash_host_configs(configs) do
    configs
    |> Enum.filter(&File.regular?/1)
    |> Enum.into(%{}, fn path ->
      {path, :crypto.hash(:sha256, File.read!(path))}
    end)
  end

  defp list_tmp_entries(tmp_dir) do
    case File.ls(tmp_dir) do
      {:ok, entries} -> entries
      {:error, _} -> []
    end
  end

  defp safe_tmp_dir do
    try do
      System.tmp_dir!()
    rescue
      _ -> "/tmp"
    end
  end
end
