defmodule MutagenEx.GitDiff do
  @moduledoc """
  Reads changed source lines against a Git merge-base and reads blobs from it.

  Diff roots must be real directories within the resolved project directory.
  Scope compares normalized root spellings and folds case when Git config or
  the disk indicates case-insensitivity. Results keep Git's path spelling,
  including case and normalization. The caller should use those keys
  directly and name the reason and path for each skipped entry when marking
  a read incomplete.

  Symlinks and gitlinks in the index at or below a root count as skipped
  even when unchanged. A changed entry can also carry its diff reason.
  Running from inside a submodule checkout is unsupported. The project
  directory cannot be redirected by a link within the checkout.

  Git runs without a shell or pager. The environment drops inherited `GIT_*`
  variables, including `GIT_EXTERNAL_DIFF`, `GIT_DIFF_OPTS`, `GIT_PAGER`,
  `GIT_TRACE*`, `GIT_CONFIG*`, `GIT_DIR`, `GIT_WORK_TREE`, `GIT_INDEX_FILE`,
  `GIT_ATTR_SOURCE`, and `GIT_*_PATHSPECS`. `GIT_CONFIG_NOSYSTEM` and
  `GIT_ATTR_NOSYSTEM` suppress system configuration and attributes.
  `GIT_OPTIONAL_LOCKS`, `GIT_NO_REPLACE_OBJECTS`, `GIT_NO_LAZY_FETCH`, and
  `GIT_ALLOW_PROTOCOL` disable optional writes, replacement objects, lazy
  fetches, and transports. `LC_ALL` is set to `C`.

  Command-line config pins `core.quotepath`, `core.attributesFile`, `core.bigFileThreshold`,
  `core.fsmonitor`, `core.hooksPath`, `core.pager`, `pager.diff`,
  `pager.show`, `color.ui`, `color.diff`, `log.showSignature`, and
  `protocol.allow`. It pins `diff.external`, `diff.noPrefix`,
  `diff.mnemonicPrefix`, `diff.srcPrefix`, `diff.dstPrefix`, `diff.relative`,
  `diff.context`, `diff.interHunkContext`, `diff.algorithm`,
  `diff.indentHeuristic`, `diff.suppressBlankEmpty`, `diff.suppress-blank-empty`,
  `diff.orderFile`, `diff.renames`, `diff.renameLimit`, `diff.ignoreSubmodules`,
  `diff.submodule`, `submodule.recurse`, and `diff.autoRefreshIndex`.
  Explicit flags disable external diff, textconv, color, notes, signatures,
  and decorations. The reader keeps standard global configuration so Git
  can enforce ownership with the runner's safe.directory entries. It never
  adds an ownership exception.

  Local driver names are open-ended. A bounded config read finds
  `filter.<driver>.{clean,smudge,process,required}` and
  `diff.<driver>.{algorithm,binary,command,textconv,cacheTextconv}`.
  `GIT_CONFIG_PARAMETERS` carries Git's command-line config encoding for
  these keys. It disables the configured programs and pins the binary and
  algorithm settings without putting variable flags in argv.
  Git 2.41 or newer is required. `GIT_ATTR_SOURCE` selects the empty tree and
  `core.autocrlf`, `core.eol`, and `core.safecrlf` are pinned for raw working
  bytes. Git's repository `info/attributes` must be empty. `GIT_WORK_TREE` is
  pinned to the discovered checkout and `GIT_GRAFT_FILE` disables grafts.
  `core.precomposeUnicode` is disabled to pass literal pathspec bytes to Git.
  `advice.graftFileDeprecated` suppresses the diagnostic for the empty graft
  file. Promisor repositories fail closed before a command can fetch.
  As with the index and worktree, keep the local config stable during the read.
  """

  defmodule Output do
    @moduledoc false
    defstruct [:limit, :keep]
  end

  @ref_pattern ~r/\A(?:[A-Za-z0-9][A-Za-z0-9._\/+-]*|HEAD(?:[~^][0-9]*)+)\z/
  @ambiguous_ref ~r/(?:\A|\n)(?:error|warning): refname '[^\n]*' is ambiguous\.?(?:\n|\z)/
  @sha_pattern ~r/\A(?:[0-9a-fA-F]{40}|[0-9a-fA-F]{64})\z/
  @raw_header ~r/\A:([0-7]{6}) ([0-7]{6}) ([0-9a-f]+) ([0-9a-f]+) ([AMDRT])(?:[0-9]{1,3})?\z/
  @numstat ~r/\A([0-9]+\t[0-9]+|-\t-)\t(.*)\z/s
  @hunk ~r/\A@@ -([0-9]{1,10})(?:,([0-9]{1,10}))? \+([0-9]{1,10})(?:,([0-9]{1,10}))? @@(?: .*)?\z/

  @max_diff_bytes 16 * 1024 * 1024
  @max_base_bytes 16 * 1024 * 1024
  @max_working_bytes 64 * 1024 * 1024
  @max_files 2_000
  @metadata_bytes 16 * 1024
  @minimum_git {2, 41}
  @default_timeout to_timeout(second: 30)
  @regular_modes ["100644", "100755"]
  @ls_files ["ls-files", "-s", "-z", "--full-name"]

  @git_config ~w(
    core.quotepath=off core.attributesFile=/dev/null core.bigFileThreshold=512m core.fsmonitor=
    core.hooksPath=/dev/null core.pager=cat pager.diff=false pager.show=false
    color.ui=false color.diff=false log.showSignature=false protocol.allow=never
    diff.external= diff.noPrefix=false diff.mnemonicPrefix=false
    diff.srcPrefix=a/ diff.dstPrefix=b/ diff.relative=false diff.context=0
    diff.interHunkContext=0 diff.algorithm=myers diff.indentHeuristic=true
    diff.suppressBlankEmpty=false diff.suppress-blank-empty=false
    diff.orderFile=/dev/null diff.renames=true diff.renameLimit=1000
    diff.ignoreSubmodules=dirty diff.submodule=short submodule.recurse=false
    core.autocrlf=false core.safecrlf=false core.eol=lf core.warnAmbiguousRefs=true
    advice.graftFileDeprecated=false core.precomposeUnicode=false
    diff.autoRefreshIndex=false
  )
  @git_options ["--no-pager" | Enum.flat_map(@git_config, &["-c", &1])]

  @safe_diff ~w(--no-ext-diff --no-textconv --no-color)
  @diff_flags @safe_diff ++
                ~w(--raw --numstat -z --patch --no-abbrev --unified=0 --find-renames --diff-filter=AMRT --text
                   --src-prefix=a/ --dst-prefix=b/ --no-relative --ignore-submodules=dirty --submodule=short)
  @show_flags @safe_diff ++ ~w(--no-patch --no-notes --no-decorate --no-show-signature)

  @git_env %{
    "GIT_ALLOW_PROTOCOL" => ":",
    "GIT_ATTR_NOSYSTEM" => "1",
    "GIT_CONFIG_NOSYSTEM" => "1",
    "GIT_GRAFT_FILE" => "/dev/null",
    "GIT_NO_LAZY_FETCH" => "1",
    "GIT_NO_REPLACE_OBJECTS" => "1",
    "GIT_OPTIONAL_LOCKS" => "0",
    "LC_ALL" => "C"
  }

  @driver_keys %{
    "filter" => %{"clean" => "", "smudge" => "", "process" => "", "required" => "false"},
    "diff" => %{
      "algorithm" => "myers",
      "binary" => "auto",
      "command" => "",
      "textconv" => "",
      "cachetextconv" => "false"
    }
  }
  @driver_pattern ~r/\A(filter|diff)\..+\.([a-z]+)\z/s
  @config_query "^(filter\\..*\\.(clean|smudge|process|required)|" <>
                  "diff\\..*\\.(algorithm|binary|command|textconv|cachetextconv)|" <>
                  "extensions\\.partialclone|remote\\..*\\.promisor)$"

  @type sha :: String.t()
  @type line_range :: {pos_integer(), pos_integer()}
  @type change_set :: %{
          optional(:deletion_anchors) => %{optional(binary()) => [non_neg_integer()]},
          base: sha(),
          head: sha() | nil,
          files: %{optional(binary()) => [line_range()]},
          renames: %{optional(binary()) => binary()},
          skipped: [%{path: binary(), reason: atom()}],
          warnings: [:empty_diff]
        }
  @type error :: {:error, :invalid_since_ref | :diff_unavailable, map()}

  @doc """
  Returns the new-side line ranges under `:roots` (default `["lib"]`).

  `:cd` selects the project directory. `:timeout` is the deadline in
  milliseconds for each Git command and defaults to 30 seconds. `:cmd` accepts a three-argument
  function with the same arguments and binary result as `System.cmd/3`.
  `:kill_cmd` can inject that same interface for timeout cleanup.
  `:renames` maps each selected destination to its old path, including pure
  renames. Git detects renames within the selected roots.
  Set `:deletion_anchors` to return a separate map of new-side line
  numbers from zero-line hunks. An anchor of 0 is before the first line.
  Set `file_kind: :test` to select changed `*_test.exs` files, including
  pure renames. The default kind is `:source` (`.ex`).
  With `:allow_missing_roots`, a missing root is part of the working-tree
  snapshot and an empty roots list selects no paths. Set `:untracked` to
  include unignored working files without requiring intent-to-add.
  """
  @spec changed_lines(binary(), keyword()) :: {:ok, change_set()} | error()
  def changed_lines(ref, opts) do
    if valid_ref?(ref) do
      with {:ok, roots} <- roots(opts),
           {:ok, git} <- git_context(opts),
           :ok <- check_version(git),
           {:ok, false} <- shallow?(git) do
        git
        |> read_changes(ref, roots, opts)
        |> with_shallow(false)
      else
        {:ok, true} ->
          unavailable(:shallow_repository, :repository, %{
            shallow: true,
            hint: "Use fetch-depth: 0 in CI to make the merge base available."
          })

        {:error, _, _} = error ->
          error
      end
    else
      {:error, :invalid_since_ref, %{cause: :invalid_ref}}
    end
  end

  @doc """
  Reads the raw blob at `base_sha` and `relative_path`, using the same options
  as `changed_lines/2`. Use the old path for a rename. Returns `:absent` when
  the commit exists and the path has no tree entry.
  """
  @spec base_file(sha(), binary(), keyword()) :: {:ok, binary()} | :absent | error()
  def base_file(base_sha, relative_path, opts) do
    with :ok <- validate_base_sha(base_sha),
         {:ok, roots} <- roots(opts),
         :ok <- validate_base_path(relative_path, roots, true),
         {:ok, git} <- git_context(opts),
         :ok <- check_version(git),
         {:ok, shallow} <- shallow?(git) do
      git
      |> read_base_file(base_sha, relative_path, roots)
      |> with_shallow(shallow)
    end
  end

  defp read_changes(git, ref, roots, opts, retry? \\ true) do
    case read_changes_once(git, ref, roots, opts) do
      {:retry, _error} when retry? -> read_changes(git, ref, roots, opts, false)
      {:retry, error} -> error
      result -> result
    end
  end

  defp read_changes_once(git, ref, roots, opts) do
    kind = Keyword.get(opts, :file_kind, :source)
    anchors? = Keyword.get(opts, :deletion_anchors, false)
    allow_missing? = Keyword.get(opts, :allow_missing_roots, false)
    git = Map.put(git, :file_kind, kind)

    with :ok <- validate_kind(kind),
         {:ok, git} <- repository_context(git),
         :ok <- check_info_attributes(git),
         :ok <- reject_ambiguous(git, ref),
         {:ok, since} <- resolve_commit(git, ref, :resolve_ref, :unresolvable_ref),
         {:ok, head} <- resolve_commit(git, "HEAD", :resolve_head, :unresolvable_head),
         {:ok, base} <- merge_base(git, since, head),
         {:ok, snapshot} <- snapshot_roots(git, roots, base, allow_missing?),
         git = probe_case(git),
         git = put_git_env(git, "GIT_ATTR_SOURCE", object_id("tree", "", head)),
         {:ok, paths, index} <- tracked_scope(git, base, roots),
         {:ok, untracked} <- untracked_paths(git, paths, roots, opts[:untracked]),
         before = snapshot_index_dirs(git, index, snapshot),
         before = Enum.reduce(untracked, before, &snapshot_parent(git.cd, &1, &2)),
         {:ok, output} <- diff_output(git, base, paths),
         {:ok, changes, changed_paths} <- parse_diff(output, roots, git),
         all_paths = Enum.uniq(changed_paths ++ untracked),
         :ok <- check_untracked_limit(changed_paths, untracked, roots, git),
         :ok <- verify_directories(git, roots, snapshot, before, all_paths),
         {:ok, changes} <- add_untracked(git, changes, untracked),
         :ok <- validate_ranges(git, changes, anchors?),
         :ok <- verify_untracked_directories(git, roots, snapshot, before, untracked) do
      changes = %{changes | skipped: changes.skipped ++ index_links(index, git)}
      changes = if anchors?, do: changes, else: Map.delete(changes, :deletion_anchors)

      warnings =
        if changes.files == %{} and Map.get(changes, :deletion_anchors, %{}) == %{} and
             changes.skipped == [],
           do: [:empty_diff],
           else: []

      {:ok, Map.merge(changes, %{base: base, head: head, warnings: warnings})}
    end
  end

  defp validate_kind(kind) when kind in [:source, :test], do: :ok
  defp validate_kind(_kind), do: unavailable(:invalid_file_kind, :diff)

  defp diff_output(_git, _base, []), do: {:ok, ""}

  defp diff_output(git, base, paths) do
    args = ["diff" | @diff_flags] ++ [base, "--" | paths]
    command(git, args, :diff, @max_diff_bytes)
  end

  defp untracked_paths(_git, _paths, _roots, flag) when flag != true, do: {:ok, []}
  defp untracked_paths(_git, [], _roots, true), do: {:ok, []}

  defp untracked_paths(git, paths, roots, true) do
    args = ["ls-files", "--others", "--exclude-standard", "-z", "--full-name", "--" | paths]

    with {:ok, output} <- command(repo_git(git), args, :untracked, @max_diff_bytes),
         ["" | names] <- Enum.reverse(:binary.split(output, <<0>>, [:global])) do
      names
      |> Enum.reverse()
      |> Enum.reduce_while({:ok, []}, fn name, {:ok, acc} ->
        path = project_relative(String.trim_trailing(name, "/"), git)

        if is_binary(path) and safe_git_path?(path) and
             root_match(path, roots, git.ignore_case?) == :below do
          if selected_file?(path, git.file_kind) or String.ends_with?(name, "/"),
            do: {:cont, {:ok, [path | acc]}},
            else: {:cont, {:ok, acc}}
        else
          {:halt, unavailable(:invalid_path, :untracked)}
        end
      end)
    else
      {:error, _, _} = error -> error
      _ -> unavailable(:invalid_output, :untracked)
    end
  end

  defp check_untracked_limit(changed, untracked, roots, git) do
    files = Enum.filter(untracked, &selected_file?(&1, git.file_kind))

    case Enum.fetch(files, @max_files - length(changed)) do
      :error ->
        :ok

      {:ok, path} ->
        root = Enum.find(roots, &(root_match(path, [&1], git.ignore_case?) == :below))
        unavailable(:file_limit, :untracked, %{limit_files: @max_files, root: root})
    end
  end

  defp add_untracked(git, changes, paths) do
    Enum.reduce_while(paths, {:ok, changes}, fn path, {:ok, changes} ->
      case untracked_change(git, changes, path) do
        {:ok, changes} -> {:cont, {:ok, changes}}
        error -> {:halt, error}
      end
    end)
  end

  defp untracked_change(git, changes, path) do
    case File.lstat(Path.join(git.cd, path)) do
      {:ok, %{type: :symlink}} ->
        add_skipped(changes, path, :symlink)

      {:ok, %{type: :directory}} ->
        add_skipped(changes, path, :nested_git_checkout)

      {:ok, %{type: :regular}} ->
        if selected_file?(path, git.file_kind) do
          with {:ok, absolute} <- regular_working_path(git.cd, path),
               {:ok, {:ok, last}} <-
                 File.open(absolute, [:read, :binary], &count_lines(&1, 0, 0, false)) do
            ranges = if last == 0, do: [], else: [{1, last}]
            {:ok, put_in(changes.files[path], ranges)}
          else
            {:error, :diff_unavailable, _} = error -> error
            {:ok, {:error, _, _} = error} -> error
            _ -> unavailable(:working_file_unavailable, :untracked)
          end
        else
          {:ok, changes}
        end

      _ ->
        unavailable(:working_file_unavailable, :untracked)
    end
  end

  defp count_lines(io, size, lines, partial?) do
    case IO.binread(io, 64 * 1024) do
      :eof ->
        {:ok, lines + if(partial?, do: 1, else: 0)}

      chunk when is_binary(chunk) and size + byte_size(chunk) <= @max_working_bytes ->
        count_lines(
          io,
          size + byte_size(chunk),
          lines + length(:binary.matches(chunk, "\n")),
          :binary.last(chunk) != ?\n
        )

      chunk when is_binary(chunk) ->
        unavailable(:working_file_limit, :untracked, %{limit_bytes: @max_working_bytes})

      _ ->
        unavailable(:working_file_unavailable, :untracked)
    end
  end

  defp verify_untracked_directories(_git, _roots, _snapshot, _before, []), do: :ok

  defp verify_untracked_directories(git, roots, snapshot, before, paths),
    do: verify_directories(git, roots, snapshot, before, paths)

  defp read_base_file(git, sha, path, roots) do
    with {:ok, git} <- repository_context(git),
         :ok <- check_index_project_links(git),
         git = probe_case(git),
         :ok <- validate_base_path(path, roots, git.ignore_case?),
         :ok <- verify_base_type(git, sha),
         path = git.prefix <> path,
         {:ok, entry} <-
           command(
             git,
             ["ls-tree", "-z", "--full-tree", sha, "--", literal_path(path)],
             :base_tree
           ),
         {:ok, blob} <- blob_entry(entry, path),
         args = ["show" | @show_flags] ++ [sha <> ":" <> path, "--"],
         {:ok, bytes} <- command(git, args, :base_file, @max_base_bytes) do
      # System.cmd captures both streams. A blob must match its tree entry.
      if object_id("blob", bytes, blob) == blob,
        do: {:ok, bytes},
        else: unavailable(:invalid_output, :base_file)
    end
  end

  defp verify_base_type(git, sha) do
    case command(git, ["cat-file", "-t", sha], :base_type) do
      {:ok, "commit\n"} ->
        :ok

      {:ok, type} when type in ["blob\n", "tree\n", "tag\n"] ->
        unavailable(:non_commit_base, :base_type)

      {:ok, _} ->
        unavailable(:invalid_output, :base_type)

      {:error, _, _} = error ->
        error
    end
  end

  defp blob_entry("", _path), do: :absent

  defp blob_entry(entry, path) do
    entry_path = path <> <<0>>

    with [header, ^entry_path] <- :binary.split(entry, "\t"),
         [mode, type, sha] <- :binary.split(header, " ", [:global]),
         true <- Regex.match?(~r/\A[0-7]{6}\z/, mode) and valid_sha?(sha) do
      case {mode, type} do
        {mode, "blob"} when mode in @regular_modes ->
          {:ok, sha}

        {"120000", "blob"} ->
          unavailable(:base_symlink, :base_tree)

        {_, type} when type in ["blob", "tree", "commit"] ->
          unavailable(:not_a_regular_file, :base_tree)

        _ ->
          unavailable(:invalid_output, :base_tree)
      end
    else
      _ -> unavailable(:invalid_output, :base_tree)
    end
  end

  defp object_id(type, bytes, oid) do
    algorithm = if byte_size(oid) == 40, do: :sha, else: :sha256
    hash = :crypto.hash(algorithm, [type, " ", Integer.to_string(byte_size(bytes)), <<0>>, bytes])
    Base.encode16(hash, case: :lower)
  end

  defp valid_ref?(ref) do
    is_binary(ref) and byte_size(ref) <= 255 and Regex.match?(@ref_pattern, ref) and
      :binary.match(ref, "..") == :nomatch
  end

  defp valid_sha?(sha) do
    is_binary(sha) and byte_size(sha) in [40, 64] and Regex.match?(@sha_pattern, sha)
  end

  defp validate_base_sha(sha) do
    cond do
      not valid_sha?(sha) -> unavailable(:invalid_base_sha, :base_file)
      String.trim(sha, "0") == "" -> unavailable(:zero_base_sha, :base_file)
      true -> :ok
    end
  end

  defp validate_base_path(path, roots, ignore_case?) do
    if relative_path?(path) and root_match(path, roots, ignore_case?) == :below,
      do: :ok,
      else: unavailable(:invalid_path, :base_file)
  end

  defp roots(opts) do
    roots = Keyword.get(opts, :roots, ["lib"])

    if is_list(roots) and (roots != [] or opts[:allow_missing_roots] == true) and
         Enum.all?(roots, &relative_path?/1),
       do: {:ok, roots},
       else: unavailable(:invalid_roots, :repository)
  end

  defp relative_path?(path) when is_binary(path) do
    not Regex.match?(~r/\A[A-Za-z]:/, path) and safe_git_path?(path)
  end

  defp relative_path?(_path), do: false

  defp safe_git_path?(path) do
    :binary.match(path, <<0>>) == :nomatch and
      not (match?({:win32, _}, :os.type()) and
             (Path.type(path) != :relative or :binary.match(path, "\\") != :nomatch)) and
      Enum.all?(path_segments(path), &(&1 not in ["", ".", ".."]))
  end

  defp root_match(nil, _roots, _ignore_case?), do: nil

  defp root_match(path, roots, ignore_case?) do
    path = path_key(path, ignore_case?)
    roots = Enum.map(roots, &path_key(&1, ignore_case?))

    cond do
      Enum.any?(roots, &String.starts_with?(path, &1 <> "/")) -> :below
      path in roots -> :root
      true -> nil
    end
  end

  defp path_key(path, false) do
    if String.valid?(path), do: String.normalize(path, :nfc), else: path
  end

  defp path_key(path, true) do
    if String.valid?(path),
      do: path |> :string.casefold() |> String.normalize(:nfc),
      else: String.downcase(path, :ascii)
  end

  defp literal_path(path), do: ":(top,literal)" <> path

  # Git's literal pathspecs preserve the index and tree's exact spelling.
  # Select the root aliases before requesting a patch or detecting renames.
  defp tracked_scope(_git, _base, []), do: {:ok, [], []}

  defp tracked_scope(git, base, roots) do
    paths = Enum.map(roots, &(git.prefix <> &1))

    keys =
      Enum.map(paths, fn path ->
        key = path_key(path, git.ignore_case?)
        {key, key <> "/", length(path_segments(path))}
      end)

    select_root = fn _mode, path -> matching_root(path, keys, git.ignore_case?) end
    select_index = fn mode, path -> select_root.(mode, path) || project_link(mode, git) end
    repo = repo_git(git)

    with {:ok, index} <-
           index_inventory(repo, select_index),
         :ok <- check_project_links(git, repo, index),
         {:ok, tree} <-
           inventory(repo, ["ls-tree", "-r", "-z", "--full-tree", base], :scope_tree, select_root) do
      in_scope = Enum.reject(index, fn {_, _, _, root} -> root == :project_link end)
      {:ok, scope_pathspecs(paths, in_scope, tree), in_scope}
    end
  end

  defp scope_pathspecs(paths, index, tree) do
    former_files =
      for {mode, _, path, root} <- tree,
          mode in @regular_modes,
          path == root,
          into: MapSet.new() do
        root
      end

    aliases = Enum.map(index ++ tree, fn {_, _, _, root} -> root end)

    for path <- Enum.uniq(paths ++ aliases) do
      literal_path(if MapSet.member?(former_files, path), do: path <> "/", else: path)
    end
  end

  defp matching_root(path, keys, ignore_case?) do
    key = path_key(path, ignore_case?)

    Enum.find_value(keys, fn {root, prefix, depth} ->
      if key == root or String.starts_with?(key, prefix) do
        path |> path_segments() |> Enum.take(depth) |> Enum.join("/")
      end
    end)
  end

  defp index_inventory(git, select), do: inventory(git, @ls_files, :index, select)

  defp inventory(git, args, step, select) do
    keep = fn record ->
      case selected_inventory_entry(record, select) do
        {:ok, _} -> true
        :ignored -> false
        :error -> throw(:git_invalid_output)
      end
    end

    with {:ok, output} <- command(git, args, step, @max_diff_bytes, keep) do
      case Enum.reverse(:binary.split(output, <<0>>, [:global])) do
        ["" | records] -> collect_inventory(Enum.reverse(records), select, step, [])
        _ -> unavailable(:invalid_output, step)
      end
    end
  end

  defp collect_inventory([], _select, _step, entries), do: {:ok, Enum.reverse(entries)}

  defp collect_inventory([record | rest], select, step, entries) do
    case selected_inventory_entry(record, select) do
      {:ok, entry} ->
        collect_inventory(rest, select, step, [entry | entries])

      :ignored ->
        collect_inventory(rest, select, step, entries)

      :error ->
        unavailable(:invalid_output, step)
    end
  end

  defp selected_inventory_entry(record, select) do
    with {:ok, mode, oid, path} <- inventory_entry(record) do
      case select.(mode, path) do
        nil -> :ignored
        match -> if safe_git_path?(path), do: {:ok, {mode, oid, path, match}}, else: :error
      end
    end
  end

  defp inventory_entry(record) do
    with [header, path] <- :binary.split(record, "\t"),
         [mode, second, third] <- :binary.split(header, " ", [:global]),
         true <- Regex.match?(~r/\A[0-7]{6}\z/, mode),
         oid when is_binary(oid) <- entry_oid(second, third),
         true <- valid_sha?(oid) do
      {:ok, mode, oid, path}
    else
      _ -> :error
    end
  end

  defp entry_oid(type, oid) when type in ["blob", "tree", "commit"], do: oid
  defp entry_oid(oid, stage) when stage in ["0", "1", "2", "3"], do: oid
  defp entry_oid(_second, _third), do: nil

  defp index_links(index, git) do
    index
    |> Enum.flat_map(fn
      {"120000", _, path, _} ->
        [%{path: project_relative(path, git), reason: :preexisting_symlink}]

      {"160000", _, path, _} ->
        [%{path: project_relative(path, git), reason: :preexisting_gitlink}]

      _ ->
        []
    end)
    |> Enum.uniq()
  end

  defp path_segments(path), do: :binary.split(path, "/", [:global])

  # Git's setting can disagree with the disk. A root such as 123 or lıb has
  # no ASCII letters to flip, but the checkout's .git entry always does.
  defp probe_case(git) do
    repo = repo_git(git)
    folds? = same_file?(Path.join(repo.cd, ".git"), Path.join(repo.cd, ".GIT"))
    %{git | ignore_case?: git.ignore_case? or folds?}
  end

  defp same_file?(path, other) do
    with {:ok, stat} <- File.stat(path),
         {:ok, other_stat} <- File.stat(other) do
      file_identity(stat) == file_identity(other_stat)
    else
      _ -> false
    end
  end

  defp file_identity(stat), do: {stat.major_device, stat.minor_device, stat.inode}

  defp snapshot_roots(git, roots, base, allow_missing?) do
    case scan_roots(git.cd, roots, allow_missing?) do
      {:ok, _} = snapshot ->
        snapshot

      {:invalid_root, root, component, :symlink} ->
        symlinked_root_error(git, base, root, component)

      {cause, root, component, type} ->
        root_error(cause, root, component, type)
    end
  end

  defp scan_roots(cd, roots, allow_missing?) do
    Enum.reduce_while(roots, {:ok, %{}}, fn root, {:ok, snapshots} ->
      case scan_components(cd, path_segments(root), "", []) do
        {:ok, entries} ->
          {:cont, {:ok, Map.put(snapshots, root, entries)}}

        {:missing, entries} when allow_missing? ->
          {:cont, {:ok, Map.put(snapshots, root, entries)}}

        {:missing, [{component, _} | _]} ->
          {:halt, {:invalid_root, root, component, :missing}}

        {cause, component, type} ->
          {:halt, {cause, root, component, type}}
      end
    end)
  end

  defp scan_components(_cd, [], _component, snapshots), do: {:ok, snapshots}

  defp scan_components(cd, [part | rest], parent, snapshots) do
    component = Path.join(parent, part)

    case directory_snapshot(Path.join(cd, component)) do
      {:ok, _} = snapshot ->
        scan_components(cd, rest, component, [{component, snapshot} | snapshots])

      {:invalid_root, :missing} = missing ->
        {:missing, [{component, missing} | snapshots]}

      {cause, type} ->
        {cause, component, type}
    end
  end

  defp directory_snapshot(path) do
    case File.lstat(path) do
      {:ok, %{type: :directory} = stat} ->
        case File.lstat(Path.join(path, ".git")) do
          {:error, :enoent} ->
            {:ok, Map.delete(stat, :atime)}

          {:ok, %{type: type}} ->
            {:nested_git_checkout, type}

          {:error, _} ->
            {:invalid_root, :inaccessible}
        end

      {:ok, %{type: type}} ->
        {:invalid_root, type}

      {:error, :enoent} ->
        {:invalid_root, :missing}

      {:error, _} ->
        {:invalid_root, :inaccessible}
    end
  end

  defp snapshot_index_dirs(git, index, roots) do
    dirs = Enum.flat_map(roots, fn {_root, snapshots} -> snapshots end) |> Map.new()

    Enum.reduce(index, dirs, fn {_, _, path, _}, snapshots ->
      snapshot_parent(git.cd, project_relative(path, git), snapshots)
    end)
  end

  defp snapshot_parent(_cd, nil, snapshots), do: snapshots

  defp snapshot_parent(cd, path, snapshots),
    do: snapshot_directory(cd, Path.dirname(path), snapshots)

  defp snapshot_directory(_cd, ".", snapshots), do: snapshots

  defp snapshot_directory(cd, component, snapshots) do
    if Map.has_key?(snapshots, component) do
      snapshots
    else
      parent = Path.dirname(component)
      snapshots = snapshot_directory(cd, parent, snapshots)

      snapshot =
        case Map.get(snapshots, parent) do
          nil -> directory_snapshot(Path.join(cd, component))
          {:ok, _} -> directory_snapshot(Path.join(cd, component))
          error -> error
        end

      Map.put(snapshots, component, snapshot)
    end
  end

  defp verify_directories(git, roots, root_snapshots, before, paths) do
    current =
      Enum.reduce(root_snapshots, %{}, fn {_root, snapshots}, acc ->
        Enum.reduce(snapshots, acc, fn {component, _}, acc ->
          snapshot_directory(git.cd, component, acc)
        end)
      end)

    current = Enum.reduce(paths, current, &snapshot_parent(git.cd, &1, &2))

    Enum.reduce_while(current, :ok, fn {component, snapshot}, result ->
      case directory_change(before[component], snapshot) do
        :none ->
          {:cont, result}

        {change, type} ->
          root =
            Enum.find(roots, fn root ->
              root_match(component, [root], git.ignore_case?) != nil or
                root_match(root, [component], git.ignore_case?) != nil
            end)

          error = root_error(:root_changed, root, component, type)
          if change == :timestamp, do: {:cont, {:retry, error}}, else: {:halt, error}
      end
    end)
  end

  defp directory_change(snapshot, snapshot), do: :none

  # Adding or removing an entry changes a directory's times, size, and link
  # count but keeps its type and identity. That case earns one retry.
  defp directory_change({:ok, before}, {:ok, current}) do
    if file_identity(before) == file_identity(current),
      do: {:timestamp, :directory},
      else: {:replaced, :directory}
  end

  defp directory_change(_, {:ok, _}), do: {:replaced, :directory}
  defp directory_change(_, {_, type}), do: {:replaced, type}

  defp symlinked_root_error(git, base, root, component) do
    path = git.prefix <> component
    args = ["ls-tree", "-z", "--full-tree", base, "--", literal_path(path)]

    with {:ok, output} <- command(git, args, :base_root) do
      cause =
        with [record, ""] <- :binary.split(output, <<0>>),
             {:ok, "120000", oid, ^path} <- inventory_entry(record),
             {:ok, target} <- File.read_link(Path.join(git.cd, component)),
             true <- object_id("blob", target, oid) == oid do
          :preexisting_symlinked_root
        else
          _ -> :invalid_root_directory
        end

      root_error(cause, root, component, :symlink)
    end
  end

  defp root_error(:invalid_root, root, component, type),
    do: root_error(:invalid_root_directory, root, component, type)

  defp root_error(cause, root, component, type) do
    unavailable(cause, :worktree, %{
      root: report_path(root || component),
      component: report_path(component),
      type: type
    })
  end

  defp report_path(path), do: Regex.replace(~r/[\p{Cc}\p{Cf}]/u, String.replace_invalid(path), "")

  defp git_context(opts) do
    cd = Keyword.get_lazy(opts, :cd, &File.cwd!/0)
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    with {:ok, cd, symlinks} <- real_cd(cd),
         true <- is_integer(timeout) and timeout > 0 do
      env =
        System.get_env()
        |> Map.keys()
        |> Enum.filter(&String.starts_with?(&1, "GIT_"))
        |> Map.new(&{&1, nil})
        |> Map.merge(@git_env)

      git = %{
        cmd: Keyword.get(opts, :cmd, &System.cmd/3),
        kill_cmd: Keyword.get(opts, :kill_cmd, &System.cmd/3),
        cd: cd,
        cd_symlinks: symlinks,
        env: env,
        timeout: timeout
      }

      case worktree_root(cd) do
        nil -> {:ok, git}
        root -> {:ok, put_git_env(git, "GIT_WORK_TREE", root)}
      end
    else
      false -> unavailable(:invalid_timeout, :repository)
      :error -> unavailable(:missing_cd, :repository)
    end
  end

  defp real_cd(cd) when is_binary(cd) and cd != "" do
    [root | parts] = cd |> Path.absname() |> Path.split()
    resolve_directory(parts, root, [], 40)
  end

  defp real_cd(_cd), do: :error

  defp resolve_directory([], dir, symlinks, _remaining), do: {:ok, dir, symlinks}

  defp resolve_directory(["." | rest], dir, symlinks, remaining),
    do: resolve_directory(rest, dir, symlinks, remaining)

  defp resolve_directory([".." | rest], dir, symlinks, remaining),
    do: resolve_directory(rest, Path.dirname(dir), symlinks, remaining)

  defp resolve_directory([part | rest], dir, symlinks, remaining) do
    path = Path.join(dir, part)

    case File.lstat(path) do
      {:ok, %{type: :directory}} ->
        resolve_directory(rest, path, symlinks, remaining)

      {:ok, %{type: :symlink}} when remaining > 0 ->
        case File.read_link(path) do
          {:ok, target} ->
            [root | parts] = target |> Path.absname(dir) |> Path.split()
            resolve_directory(parts ++ rest, root, [path | symlinks], remaining - 1)

          _ ->
            :error
        end

      _ ->
        :error
    end
  end

  # Git's top-level probe can honor core.worktree. Discover the checkout
  # from its .git marker before giving Git a chance to read that setting.
  defp worktree_root(dir) do
    parent = Path.dirname(dir)

    cond do
      File.exists?(Path.join(dir, ".git")) -> dir
      File.regular?(Path.join(dir, "HEAD")) and File.dir?(Path.join(dir, "objects")) -> nil
      parent == dir -> nil
      true -> worktree_root(parent)
    end
  end

  defp put_git_env(git, key, value), do: %{git | env: Map.put(git.env, key, value)}

  defp repo_git(git), do: %{git | cd: git.env["GIT_WORK_TREE"] || git.cd}

  defp check_version(git) do
    with {:ok, output} <- command(git, ["version"], :version) do
      case Regex.run(~r/\Agit version ([0-9]+)\.([0-9]+)(?:[.\s]|\z)/, output, capture: [1, 2]) do
        [major, minor] ->
          if {String.to_integer(major), String.to_integer(minor)} >= @minimum_git do
            :ok
          else
            unavailable(:unsupported_git_version, :version, %{minimum: "2.41"})
          end

        _ ->
          unavailable(:invalid_output, :version)
      end
    end
  end

  defp repository_context(git) do
    with :ok <- require_worktree(git),
         :ok <- require_superproject_boundary(git),
         :ok <- check_checkout_boundaries(git),
         {:ok, git} <- neutralize_drivers(git),
         {:ok, ignore_case?} <- ignore_case(git),
         {:ok, output} <- command(git, ["rev-parse", "--show-prefix"], :worktree),
         {:ok, prefix} <- output_line(output, :worktree) do
      if prefix == "" or
           (String.ends_with?(prefix, "/") and
              relative_path?(binary_part(prefix, 0, byte_size(prefix) - 1))) do
        {:ok, Map.merge(git, %{prefix: prefix, ignore_case?: ignore_case?})}
      else
        unavailable(:invalid_output, :worktree)
      end
    end
  end

  defp require_worktree(git, step \\ :worktree) do
    case command(git, ["rev-parse", "--is-inside-work-tree"], step) do
      {:ok, "true\n"} -> :ok
      {:ok, _} -> unavailable(:not_inside_worktree, step)
      error -> error
    end
  end

  defp require_superproject_boundary(git) do
    case command(git, ["rev-parse", "--show-superproject-working-tree"], :worktree) do
      {:ok, ""} ->
        :ok

      {:ok, _} ->
        inside_submodule()

      error ->
        error
    end
  end

  # Git finds a superproject only through an exact index match, which a
  # case-insensitive disk can defeat. Module metadata and folded gitlinks in
  # enclosing checkouts identify a submodule without that lookup.
  defp check_checkout_boundaries(%{env: %{"GIT_WORK_TREE" => root}} = git) when is_binary(root) do
    with :ok <- check_module_git_dir(git),
         :ok <- check_enclosing_gitlinks(git, root, Path.dirname(root)) do
      check_cd_symlinks(git, root)
    end
  end

  defp check_checkout_boundaries(_git), do: :ok

  defp check_module_git_dir(git) do
    with {:ok, output} <- command(git, ["rev-parse", "--absolute-git-dir"], :worktree),
         {:ok, git_dir} <- output_line(output, :worktree) do
      cond do
        Path.type(git_dir) != :absolute or :binary.match(git_dir, <<0>>) != :nomatch ->
          unavailable(:invalid_output, :worktree)

        module_git_dir?(git_dir) ->
          inside_submodule()

        true ->
          :ok
      end
    end
  end

  # Git keeps a submodule's repository under <git-dir>/modules/<name>. Only a
  # modules directory inside a Git directory counts, so a checkout below an
  # ordinary directory named modules still reads.
  defp module_git_dir?(dir) do
    parent = Path.dirname(dir)

    cond do
      parent == dir -> false
      Path.basename(parent) == "modules" and git_directory?(Path.dirname(parent)) -> true
      true -> module_git_dir?(parent)
    end
  end

  defp git_directory?(dir), do: File.regular?(Path.join(dir, "HEAD"))

  defp check_enclosing_gitlinks(git, root, dir) do
    case worktree_root(dir) do
      nil ->
        :ok

      parent ->
        enclosing = put_git_env(%{git | cd: parent}, "GIT_WORK_TREE", parent)
        key = path_key(Path.relative_to(root, parent), true)

        select = fn
          "160000", path -> if path_key(path, true) == key, do: :enclosing_gitlink
          _mode, _path -> nil
        end

        with :ok <- require_worktree(enclosing, :enclosing_repository),
             {:ok, []} <- inventory(enclosing, @ls_files, :enclosing_repository, select) do
          check_enclosing_gitlinks(git, root, Path.dirname(parent))
        else
          {:ok, _gitlinks} -> inside_submodule()
          error -> error
        end
    end
  end

  defp check_cd_symlinks(git, root) do
    identity = directory_identity(root)

    case Enum.find(git.cd_symlinks, &inside_directory?(Path.dirname(&1), identity)) do
      nil -> :ok
      link -> symlinked_project(link)
    end
  end

  defp inside_submodule do
    unavailable(:inside_submodule, :worktree, %{
      hint: "Running Mutagen from inside a submodule checkout is not supported."
    })
  end

  defp symlinked_project(link) do
    unavailable(:symlinked_project_directory, :worktree, %{component: report_path(link)})
  end

  defp directory_identity(dir) do
    case File.stat(dir) do
      {:ok, %{type: :directory} = stat} -> file_identity(stat)
      _ -> nil
    end
  end

  defp inside_directory?(_dir, nil), do: false

  defp inside_directory?(dir, identity) do
    parent = Path.dirname(dir)
    directory_identity(dir) == identity or (parent != dir and inside_directory?(parent, identity))
  end

  # A link can redirect only a nested project. The caller may pass a path
  # that the shell already resolved, so check where tracked links lead.
  defp project_link("120000", %{prefix: prefix}) when prefix != "", do: :project_link
  defp project_link(_mode, _git), do: nil

  defp check_index_project_links(%{prefix: ""}), do: :ok

  defp check_index_project_links(git) do
    repo = repo_git(git)

    with {:ok, index} <- index_inventory(repo, fn mode, _path -> project_link(mode, git) end) do
      check_project_links(git, repo, index)
    end
  end

  defp check_project_links(%{prefix: ""}, _repo, _index), do: :ok

  defp check_project_links(git, repo, index) do
    case Enum.uniq(for {"120000", oid, path, _} <- index, do: {oid, path}) do
      [] ->
        :ok

      links ->
        ancestors = project_ancestors(git.cd, directory_identity(repo.cd), MapSet.new())
        check_link_targets(links, repo, ancestors)
    end
  end

  defp project_ancestors(dir, root, ancestors) do
    identity = directory_identity(dir)
    ancestors = MapSet.put(ancestors, identity)
    parent = Path.dirname(dir)

    if identity == root or parent == dir,
      do: ancestors,
      else: project_ancestors(parent, root, ancestors)
  end

  defp check_link_targets([], _repo, _ancestors), do: :ok

  defp check_link_targets([{oid, path} | rest], repo, ancestors) do
    link = Path.join(repo.cd, path)

    with {:ok, targets} <- link_targets(repo, link, oid) do
      if Enum.any?(targets, &project_target?(&1, Path.dirname(link), ancestors)),
        do: symlinked_project(path),
        else: check_link_targets(rest, repo, ancestors)
    end
  end

  # A checkout normally matches its index, so Git reads the blob only when
  # the link on disk is missing or differs.
  defp link_targets(repo, link, oid) do
    case File.read_link(link) do
      {:ok, live} ->
        if object_id("blob", live, oid) == oid,
          do: {:ok, [live]},
          else: indexed_link_target(repo, oid, [live])

      {:error, _} ->
        indexed_link_target(repo, oid, [])
    end
  end

  defp indexed_link_target(repo, oid, targets) do
    with {:ok, target} <- command(repo, ["cat-file", "blob", oid], :index_link),
         do: {:ok, [target | targets]}
  end

  defp project_target?("", _parent, _ancestors), do: false

  defp project_target?(target, parent, ancestors) do
    with :nomatch <- :binary.match(target, <<0>>),
         {:ok, dir, _symlinks} <- real_cd(Path.absname(target, parent)),
         identity when not is_nil(identity) <- directory_identity(dir) do
      MapSet.member?(ancestors, identity)
    else
      _ -> false
    end
  end

  defp ignore_case(git) do
    case run(git, ["config", "--type=bool", "--get", "core.ignorecase"], :config, @metadata_bytes) do
      {:ok, "true\n", 0} -> {:ok, true}
      {:ok, "false\n", 0} -> {:ok, false}
      {:ok, "", 1} -> {:ok, false}
      {:ok, _, status} -> unavailable(:invalid_output, :config, %{status: status})
      error -> error
    end
  end

  defp check_info_attributes(git) do
    args = ["rev-parse", "--path-format=absolute", "--git-path", "info/attributes"]

    with {:ok, output} <- command(git, args, :info_attributes),
         {:ok, path} <- output_line(output, :info_attributes),
         true <- Path.type(path) == :absolute and :binary.match(path, <<0>>) == :nomatch do
      case File.lstat(path) do
        {:ok, %{type: :regular, size: 0}} -> :ok
        {:error, :enoent} -> :ok
        _ -> unavailable(:info_attributes, :info_attributes)
      end
    else
      false -> unavailable(:invalid_output, :info_attributes)
      error -> error
    end
  end

  defp output_line(output, step) do
    size = max(byte_size(output) - 1, 0)

    case output do
      <<line::binary-size(size), "\n">> -> {:ok, line}
      _ -> unavailable(:invalid_output, step)
    end
  end

  defp reject_ambiguous(git, ref) do
    args = [
      "rev-parse",
      "--verify",
      "--quiet",
      "--symbolic-full-name",
      "--end-of-options",
      String.split(ref, ["~", "^"], parts: 2) |> hd()
    ]

    case run(git, args, :resolve_ref, @metadata_bytes) do
      {:ok, output, status} when status in [0, 1] ->
        if Regex.match?(@ambiguous_ref, output) do
          unavailable(:ambiguous_ref, :resolve_ref, %{
            hint: "Use a full ref such as refs/heads/main or refs/tags/v1."
          })
        else
          :ok
        end

      {:ok, _, status} ->
        unavailable(:git_exit, :resolve_ref, %{status: status})

      error ->
        error
    end
  end

  defp shallow?(git) do
    case run(git, ["rev-parse", "--is-shallow-repository"], :repository, @metadata_bytes) do
      {:ok, "true\n", 0} ->
        {:ok, true}

      {:ok, "false\n", 0} ->
        {:ok, false}

      {:ok, _, 0} ->
        unavailable(:invalid_output, :repository)

      {:ok, "fatal: not a git repository" <> _, status} ->
        unavailable(:not_a_git_repository, :repository, %{status: status})

      {:ok, _, status} ->
        unavailable(:git_exit, :repository, %{status: status})

      {:error, _, _} = error ->
        error
    end
  end

  defp resolve_commit(git, ref, step, cause) do
    args = ["rev-parse", "--verify", "--quiet", "--end-of-options", ref <> "^{commit}"]

    case run(git, args, step, @metadata_bytes) do
      {:ok, output, 0} -> parse_sha(output, step)
      {:ok, _, status} when status in [1, 128] -> unavailable(cause, step, %{status: status})
      {:ok, _, status} -> unavailable(:git_exit, step, %{status: status})
      {:error, _, _} = error -> error
    end
  end

  defp merge_base(git, since, head) do
    case run(git, ["merge-base", since, head], :merge_base, @metadata_bytes) do
      {:ok, output, 0} -> parse_sha(output, :merge_base)
      {:ok, _, 1} -> unavailable(:no_merge_base, :merge_base, %{status: 1})
      {:ok, _, status} -> unavailable(:git_exit, :merge_base, %{status: status})
      {:error, _, _} = error -> error
    end
  end

  defp parse_sha(output, step) do
    case :binary.split(output, "\n") do
      [sha, ""] ->
        if valid_sha?(sha), do: {:ok, sha}, else: unavailable(:invalid_output, step)

      _ ->
        unavailable(:invalid_output, step)
    end
  end

  defp neutralize_drivers(git) do
    args = ["config", "--null", "--name-only", "--get-regexp", @config_query]

    case run(git, args, :config, @metadata_bytes) do
      {:ok, "", 1} ->
        {:ok, git}

      {:ok, output, 0} ->
        with {:ok, parameters} <- driver_overrides(output) do
          {:ok, put_git_env(git, "GIT_CONFIG_PARAMETERS", parameters)}
        end

      {:ok, _, status} ->
        unavailable(:git_exit, :config, %{status: status})

      {:error, _, _} = error ->
        error
    end
  end

  defp driver_overrides(output) do
    case Enum.reverse(:binary.split(output, <<0>>, [:global])) do
      ["" | keys] ->
        keys
        |> Enum.uniq()
        |> Enum.reduce_while({:ok, []}, &driver_parameter/2)
        |> then(fn
          {:ok, parameters} -> {:ok, Enum.join(parameters, " ")}
          error -> error
        end)

      _ ->
        unavailable(:invalid_output, :config)
    end
  end

  defp driver_parameter(key, {:ok, parameters}) do
    case driver_value(key) do
      {:ok, value} ->
        {:cont, {:ok, [config_quote(key) <> "=" <> config_quote(value) | parameters]}}

      {:error, _, _} = error ->
        {:halt, error}
    end
  end

  # Git decodes this directly. The key and value are quoted separately so a
  # subsection containing an equals sign cannot change the parsed key.
  defp config_quote(value), do: "'" <> :binary.replace(value, "'", "'\\''", [:global]) <> "'"

  defp driver_value("extensions.partialclone"), do: promisor_repository()
  defp driver_value("remote." <> _), do: promisor_repository()

  defp driver_value(key) do
    with true <- String.valid?(key),
         [section, setting] <- Regex.run(@driver_pattern, key, capture: :all_but_first),
         {:ok, value} <- Map.fetch(@driver_keys[section], setting) do
      {:ok, value}
    else
      _ -> unavailable(:invalid_output, :config)
    end
  end

  defp promisor_repository do
    unavailable(:promisor_repository, :config, %{
      hint: "Use a full checkout without partial-clone filters or promisor remotes."
    })
  end

  defp command(git, args, step, limit \\ @metadata_bytes, keep \\ nil) do
    case run(git, args, step, limit, keep) do
      {:ok, output, 0} -> {:ok, output}
      {:ok, _, status} -> unavailable(:git_exit, step, %{status: status})
      {:error, _, _} = error -> error
    end
  end

  defp run(git, args, step, limit, keep \\ nil) do
    opts = [
      cd: git.cd,
      env: git.env,
      into: %Output{limit: limit, keep: keep},
      stderr_to_stdout: true
    ]

    case timed_cmd(git, @git_options ++ args, opts) do
      {:timeout, :ok} ->
        unavailable(:timeout, step, %{timeout_ms: git.timeout})

      {:timeout, :error} ->
        unavailable(:timeout, step, %{timeout_ms: git.timeout, child_may_still_run: true})

      {"fatal: detected dubious ownership" <> _, status} when status != 0 ->
        checkout = git.env["GIT_WORK_TREE"] || git.cd
        unavailable(:dubious_ownership, step, %{status: status, hint: ownership_hint(checkout)})

      {output, status}
      when is_binary(output) and is_integer(status) and byte_size(output) <= limit ->
        {:ok, output, status}

      {output, _status} when is_binary(output) and byte_size(output) > limit ->
        unavailable(:output_limit, step, %{limit_bytes: limit})

      _ ->
        unavailable(:invalid_output, step)
    end
  rescue
    error in ErlangError ->
      case error.original do
        :enoent -> unavailable(:git_not_installed, step)
        _ -> unavailable(:git_start_failed, step)
      end
  catch
    :git_output_limit -> unavailable(:output_limit, step, %{limit_bytes: limit})
    :git_invalid_output -> unavailable(:invalid_output, step)
  end

  defp ownership_hint(checkout) do
    printable = report_path(checkout)
    hint = "Git refused #{inspect(printable)}. Run as the owning user"

    if printable == checkout do
      hint <> " or run git config --global --add safe.directory " <> config_quote(checkout)
    else
      hint <> ". The checkout path contains characters omitted from this diagnostic."
    end
  end

  defp timed_cmd(git, args, opts) do
    task =
      Task.async(fn ->
        try do
          {:result, git.cmd.("git", args, opts)}
        catch
          kind, reason ->
            if reason in [:git_output_limit, :git_invalid_output],
              do: kill_child(git.kill_cmd, self())

            {kind, reason, __STACKTRACE__}
        end
      end)

    case Task.yield(task, git.timeout) do
      {:ok, {:result, result}} ->
        result

      {:ok, {kind, reason, stacktrace}} ->
        :erlang.raise(kind, reason, stacktrace)

      nil ->
        cleanup = kill_child(git.kill_cmd, task.pid)
        Task.yield(task, to_timeout(millisecond: 100)) || Task.shutdown(task, :brutal_kill)
        {:timeout, cleanup}
    end
  end

  # OTP starts each Unix port command in its own session and process group.
  defp kill_child(kill_cmd, owner) do
    results =
      for port <- Port.list(),
          Port.info(port, :connected) == {:connected, owner},
          {:os_pid, pid} <- [Port.info(port, :os_pid)],
          is_integer(pid) do
        {program, args} =
          case :os.type() do
            {:win32, _} -> {"taskkill", ["/F", "/T", "/PID", Integer.to_string(pid)]}
            _ -> {"/bin/kill", ["-KILL", "--", Integer.to_string(-pid)]}
          end

        kill_cmd.(program, args, stderr_to_stdout: true)
      end

    if Enum.all?(results, &match?({_, 0}, &1)), do: :ok, else: :error
  rescue
    ErlangError -> :error
  end

  defp with_shallow({:error, reason, details}, shallow),
    do: {:error, reason, Map.put(details, :shallow, shallow)}

  defp with_shallow(result, _shallow), do: result

  defp unavailable(cause, step, details \\ %{}),
    do: {:error, :diff_unavailable, Map.merge(details, %{cause: cause, step: step})}

  defp empty_changes, do: %{files: %{}, deletion_anchors: %{}, renames: %{}, skipped: []}

  defp parse_diff("", _roots, _git), do: {:ok, empty_changes(), []}

  # Raw records include modes, while numstat identifies patch order. Git can
  # emit a binary numstat record for an unchanged file whose stat data changed.
  defp parse_diff(output, roots, git) do
    with {:ok, fields, patch} <- diff_sections(output),
         {:ok, raw, stats} <- raw_records(fields, %{}),
         {:ok, records} <- stat_records(stats, raw, [], git),
         paths = changed_paths(records, roots, git),
         :ok <- check_file_limit(paths),
         {:ok, changes} <- patches(patch, records, roots, git, empty_changes()) do
      {:ok, changes, paths}
    end
  end

  defp diff_sections(output) do
    case :binary.split(output, <<0, 0>>) do
      [metadata, patch] -> {:ok, :binary.split(metadata, <<0>>, [:global]), patch}
      [_output] -> unavailable(:invalid_output, :diff)
    end
  end

  defp changed_paths(records, roots, git) do
    Enum.flat_map(records, fn {path, _old_path, status, _mode} ->
      path = project_relative(path, git)
      if status != "D" and root_match(path, roots, git.ignore_case?), do: [path], else: []
    end)
  end

  defp check_file_limit(paths) do
    if length(paths) <= @max_files,
      do: :ok,
      else: unavailable(:file_limit, :diff, %{limit_files: @max_files})
  end

  defp raw_records([":" <> _ = header, path | rest], records) do
    case {Regex.run(@raw_header, header, capture: :all_but_first), rest} do
      {[_, mode, old, _, "R"], [new_path | tail]} ->
        add_record(new_path, path, {"R", mode, old, false}, tail, records)

      {[old_mode, mode, old, object, status], _} when status != "R" ->
        stat_only? = status == "M" and mode == old_mode and String.trim(object, "0") == ""
        add_record(path, nil, {status, mode, old, stat_only?}, rest, records)

      _ ->
        unavailable(:invalid_output, :diff)
    end
  end

  defp raw_records(fields, records), do: {:ok, records, fields}

  defp add_record(path, old_path, entry, rest, records) do
    if relative_path?(path) and (is_nil(old_path) or relative_path?(old_path)) do
      raw_records(rest, Map.put(records, {path, old_path}, entry))
    else
      unavailable(:invalid_path, :diff)
    end
  end

  defp stat_records([], raw, records, _git) do
    if Enum.all?(raw, fn {_, {_status, _mode, _oid, stat_only?}} -> stat_only? end),
      do: {:ok, Enum.reverse(records)},
      else: unavailable(:invalid_output, :diff)
  end

  defp stat_records([header | rest], raw, records, git) do
    case {Regex.run(@numstat, header, capture: :all_but_first), rest} do
      {[_counts, ""], [old_path, path | tail]} ->
        add_stat({path, old_path}, false, tail, raw, records, git)

      {[counts, path], _} when path != "" ->
        add_stat({path, nil}, counts == "-\t-", rest, raw, records, git)

      _ ->
        unavailable(:invalid_output, :diff)
    end
  end

  defp add_stat({path, old_path} = key, binary?, rest, raw, records, git) do
    case Map.pop(raw, key) do
      {{status, mode, old_oid, true}, raw} when binary? and mode in @regular_modes ->
        with {:ok, unchanged?} <- unchanged_binary?(git, path, old_oid) do
          records = if unchanged?, do: records, else: [{path, old_path, status, mode} | records]
          stat_records(rest, raw, records, git)
        end

      {{status, mode, _, _}, raw} ->
        stat_records(rest, raw, [{path, old_path, status, mode} | records], git)

      {nil, _} ->
        unavailable(:invalid_output, :diff)
    end
  end

  # Git reports "- -" in numstat even with --text. Compare the raw blob ID
  # only when the raw record could be a timestamp change with no patch.
  defp unchanged_binary?(git, path, old_oid) do
    git = repo_git(git)

    with {:ok, _} <- regular_working_path(git.cd, path),
         {:ok, output} <-
           command(git, ["hash-object", "--no-filters", "--", path], :hash_working_file),
         {:ok, oid} <- parse_sha(output, :hash_working_file) do
      {:ok, old_oid == oid}
    end
  end

  defp patches("", [], _roots, _git, result),
    do: {:ok, %{result | skipped: Enum.reverse(result.skipped)}}

  defp patches(patch, [{path, old_path, status, mode} | records], roots, git, result) do
    with {:ok, ranges, binary?, rest} <- patch_for(patch, status),
         entry = {project_relative(path, git), project_relative(old_path, git), status, mode},
         {:ok, result} <- put_change(entry, ranges, binary?, roots, git, result) do
      patches(rest, records, roots, git, result)
    end
  end

  defp patches(_, _, _, _, _), do: unavailable(:invalid_output, :diff)

  defp patch_for(patch, "T") do
    with {:ok, _, _, rest} <- patch_section(patch),
         {:ok, _, _, rest} <- patch_section(rest) do
      {:ok, [], false, rest}
    end
  end

  defp patch_for(patch, _status), do: patch_section(patch)

  defp patch_section("diff --git " <> section) do
    case :binary.split(section, "\n") do
      [_paths, body] -> hunks(body, [], false)
      _ -> unavailable(:invalid_output, :diff)
    end
  end

  defp patch_section(_), do: unavailable(:invalid_output, :diff)

  defp project_relative(nil, _git), do: nil
  defp project_relative(path, %{prefix: ""}), do: path

  defp project_relative(path, %{prefix: prefix, ignore_case?: ignore_case?}) do
    components = path_segments(prefix) |> Enum.drop(-1)
    {directory, relative} = Enum.split(path_segments(path), length(components))

    if relative != [] and
         path_key(Enum.join(directory, "/"), ignore_case?) ==
           path_key(Enum.join(components, "/"), ignore_case?) do
      Enum.join(relative, "/")
    end
  end

  defp put_change({_path, _, "D", _}, _ranges, _binary?, _roots, _git, result),
    do: {:ok, result}

  defp put_change({path, old_path, status, mode}, ranges, binary?, roots, git, result) do
    ignore_case? = git.ignore_case?
    relation = root_match(path, roots, ignore_case?)

    cond do
      relation != nil and (mode in ["120000", "160000"] or status == "T") ->
        result =
          if status == "R" and root_match(old_path, roots, ignore_case?) != nil,
            do: put_in(result.renames[path], old_path),
            else: result

        add_skipped(result, path, skip_reason(status, mode, binary?))

      relation == :below and selected_file?(path, git.file_kind) ->
        with {:ok, result} <- put_rename(result, path, old_path, status, roots, ignore_case?) do
          case skip_reason(status, mode, binary?) do
            nil -> {:ok, put_ranges(result, path, ranges, git.file_kind)}
            reason -> add_skipped(result, path, reason)
          end
        end

      true ->
        {:ok, result}
    end
  end

  defp selected_file?(path, :source), do: String.ends_with?(path, ".ex")
  defp selected_file?(path, :test), do: String.ends_with?(path, "_test.exs")

  defp put_ranges(result, path, hunks, kind) do
    {anchors, ranges} = Enum.split_with(hunks, &is_integer/1)
    result = if anchors == [], do: result, else: put_in(result.deletion_anchors[path], anchors)

    if ranges != [] or kind == :test, do: put_in(result.files[path], ranges), else: result
  end

  defp add_skipped(result, path, reason) do
    {:ok, %{result | skipped: [%{path: path, reason: reason} | result.skipped]}}
  end

  defp skip_reason("T", _mode, _binary?), do: :type_change
  defp skip_reason(_status, "120000", _binary?), do: :symlink
  defp skip_reason(_status, "160000", _binary?), do: :gitlink
  defp skip_reason(_status, mode, _) when mode not in @regular_modes, do: :unsupported_mode
  defp skip_reason(_status, _mode, true), do: :binary
  defp skip_reason(_status, _mode, false), do: nil

  defp put_rename(result, _path, _old_path, status, _roots, _ignore_case?) when status != "R",
    do: {:ok, result}

  defp put_rename(result, path, old_path, "R", roots, ignore_case?) do
    if root_match(old_path, roots, ignore_case?) == :below,
      do: {:ok, put_in(result.renames[path], old_path)},
      else: unavailable(:invalid_path, :diff)
  end

  defp hunks("", ranges, binary?), do: {:ok, Enum.reverse(ranges), binary?, ""}

  defp hunks("diff --git " <> _ = rest, ranges, binary?),
    do: {:ok, Enum.reverse(ranges), binary?, rest}

  defp hunks(patch, ranges, binary?) do
    case :binary.split(patch, "\n") do
      ["@@" <> _ = line, rest] ->
        read_hunk(line, rest, ranges, binary?)

      ["Binary files " <> _, rest] ->
        hunks(rest, ranges, true)

      [line, rest] ->
        if patch_metadata?(line),
          do: hunks(rest, ranges, binary?),
          else: unavailable(:invalid_output, :diff)

      _ ->
        unavailable(:invalid_output, :diff)
    end
  end

  defp patch_metadata?(line) do
    String.starts_with?(line, [
      "index ",
      "--- ",
      "+++ ",
      "new file mode ",
      "deleted file mode ",
      "old mode ",
      "new mode ",
      "similarity index ",
      "dissimilarity index ",
      "rename from ",
      "rename to "
    ]) or line == "\\ No newline at end of file"
  end

  defp read_hunk(line, rest, ranges, binary?) do
    with [old_from, old_count, from, count] <- Regex.run(@hunk, line, capture: [1, 2, 3, 4]),
         {old_from, old_count} <- parse_range(old_from, old_count),
         {from, count} <- parse_range(from, count),
         true <- (old_from > 0 or old_count == 0) and (from > 0 or count == 0),
         {:ok, rest} <- hunk_body(rest, old_count, count) do
      ranges = [if(count == 0, do: from, else: {from, from + count - 1}) | ranges]
      hunks(rest, ranges, binary?)
    else
      {:error, _, _} = error -> error
      _ -> unavailable(:invalid_output, :diff)
    end
  end

  defp parse_range(from, ""), do: {String.to_integer(from), 1}
  defp parse_range(from, count), do: {String.to_integer(from), String.to_integer(count)}

  defp hunk_body(rest, 0, 0), do: {:ok, rest}

  defp hunk_body(patch, old, new) do
    case :binary.split(patch, "\n") do
      ["-" <> _, rest] when old > 0 -> hunk_body(rest, old - 1, new)
      ["+" <> _, rest] when new > 0 -> hunk_body(rest, old, new - 1)
      ["\\ No newline at end of file", rest] -> hunk_body(rest, old, new)
      _ -> unavailable(:invalid_output, :diff)
    end
  end

  defp validate_ranges(git, changes, anchors?) do
    last_lines =
      Map.new(changes.files, fn {path, ranges} ->
        {path, Enum.reduce(ranges, 0, fn {_from, to}, last -> max(to, last) end)}
      end)

    last_lines =
      if anchors? do
        last_lines =
          Enum.reduce(changes.deletion_anchors, last_lines, fn {path, anchors}, acc ->
            last = Enum.max(anchors)
            Map.update(acc, path, last, &max(&1, last))
          end)

        Enum.reduce(Map.keys(changes.renames), last_lines, &Map.put_new(&2, &1, 0))
      else
        last_lines
      end

    Enum.reduce_while(last_lines, :ok, fn {path, last_line}, :ok ->
      case validate_file_range(git.cd, path, last_line) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp validate_file_range(cd, project_path, last_line) do
    with {:ok, path} <- regular_working_path(cd, project_path) do
      case File.open(path, [:read, :binary], &enough_lines?(&1, last_line, 0, false)) do
        {:ok, true} -> :ok
        {:ok, false} -> unavailable(:invalid_hunk_range, :diff)
        _ -> unavailable(:working_file_unavailable, :diff)
      end
    end
  end

  defp regular_working_path(cd, path) do
    with {:ok, safe_path} <- Path.safe_relative(path, cd),
         absolute = Path.join(cd, safe_path),
         {:ok, %{type: :regular, size: size}} <- File.lstat(Path.join(cd, path)),
         true <- size <= @max_working_bytes do
      {:ok, absolute}
    else
      false -> unavailable(:working_file_limit, :diff, %{limit_bytes: @max_working_bytes})
      _ -> unavailable(:working_file_unavailable, :diff)
    end
  end

  defp enough_lines?(_io, needed, count, _last_partial?) when count >= needed, do: true

  defp enough_lines?(io, needed, count, last_partial?) do
    case IO.binread(io, 64 * 1024) do
      :eof ->
        last_partial? and count + 1 == needed

      bytes when is_binary(bytes) and byte_size(bytes) > 0 ->
        count = count + length(:binary.matches(bytes, "\n"))
        enough_lines?(io, needed, count, :binary.last(bytes) != ?\n)

      _ ->
        :error
    end
  end

  defimpl Collectable, for: Output do
    def into(%{limit: limit, keep: nil}) do
      {{[], 0},
       fn
         acc, {:cont, bytes} -> append(acc, bytes, limit)
         {chunks, _}, :done -> chunks |> Enum.reverse() |> IO.iodata_to_binary()
         _, :halt -> :ok
       end}
    end

    def into(%{limit: limit, keep: keep}) do
      {{{[], 0}, ""},
       fn
         {acc, pending}, {:cont, bytes} ->
           [pending | reversed] =
             :binary.split(pending <> bytes, <<0>>, [:global]) |> Enum.reverse()

           acc =
             reversed
             |> Enum.reverse()
             |> Enum.reduce(acc, fn record, acc ->
               if keep.(record), do: append(acc, record <> <<0>>, limit), else: acc
             end)

           if byte_size(pending) > limit, do: throw(:git_invalid_output)
           {acc, pending}

         {{chunks, _}, ""}, :done ->
           chunks |> Enum.reverse() |> IO.iodata_to_binary()

         _, :done ->
           throw(:git_invalid_output)

         _, :halt ->
           :ok
       end}
    end

    defp append({chunks, size}, bytes, limit) when size + byte_size(bytes) <= limit,
      do: {[bytes | chunks], size + byte_size(bytes)}

    defp append(_, _, _), do: throw(:git_output_limit)
  end
end
