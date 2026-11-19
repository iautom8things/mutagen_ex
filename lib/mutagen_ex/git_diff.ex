defmodule MutagenEx.GitDiff do
  @moduledoc """
  Reads changed source lines against a Git merge-base and reads blobs from it.

  Diff roots must be real directories within the resolved project directory.
  Case-insensitive checkouts use case-folded scope with tracked path spelling.
  A changed symlink or gitlink at or below a root counts as a skipped entry.

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
  `advice.graftFileDeprecated` suppresses the diagnostic for the empty graft
  file. Promisor repositories fail closed before a command can fetch.
  As with the index and worktree, keep the local config stable during the read.
  """

  defmodule Output do
    @moduledoc false
    defstruct [:limit]
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
    advice.graftFileDeprecated=false
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
  `:renames` maps each selected destination to its old path, including pure
  renames. Git detects renames within the selected roots.
  """
  @spec changed_lines(binary(), keyword()) :: {:ok, change_set()} | error()
  def changed_lines(ref, opts) do
    if valid_ref?(ref) do
      with {:ok, roots} <- roots(opts),
           {:ok, git} <- git_context(opts),
           :ok <- check_version(git),
           {:ok, false} <- shallow?(git) do
        git
        |> read_changes(ref, roots)
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

  defp read_changes(git, ref, roots) do
    with {:ok, git} <- repository_context(git),
         :ok <- validate_root_directories(git.cd, roots),
         :ok <- check_info_attributes(git),
         :ok <- reject_ambiguous(git, ref),
         {:ok, since} <- resolve_commit(git, ref, :resolve_ref, :unresolvable_ref),
         {:ok, head} <- resolve_commit(git, "HEAD", :resolve_head, :unresolvable_head),
         {:ok, base} <- merge_base(git, since, head),
         git = put_git_env(git, "GIT_ATTR_SOURCE", object_id("tree", "", head)),
         paths = diff_paths(git, roots),
         args = ["diff" | @diff_flags] ++ [base, "--" | paths],
         {:ok, output} <- command(git, args, :diff, @max_diff_bytes),
         {:ok, changes} <- parse_diff(output, roots, git),
         :ok <- validate_ranges(git, changes.files) do
      warnings = if changes.files == %{} and changes.skipped == [], do: [:empty_diff], else: []
      {:ok, Map.merge(changes, %{base: base, head: head, warnings: warnings})}
    end
  end

  defp read_base_file(git, sha, path, roots) do
    with {:ok, git} <- repository_context(git),
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

    if is_list(roots) and roots != [] and Enum.all?(roots, &relative_path?/1),
      do: {:ok, roots},
      else: unavailable(:invalid_roots, :repository)
  end

  defp relative_path?(path) when is_binary(path) do
    :binary.match(path, <<0>>) == :nomatch and
      not Regex.match?(~r/\A[A-Za-z]:/, path) and
      not (match?({:win32, _}, :os.type()) and :binary.match(path, "\\") != :nomatch) and
      Enum.all?(:binary.split(path, "/", [:global]), &(&1 not in ["", ".", ".."]))
  end

  defp relative_path?(_path), do: false

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

  defp path_key(path, false), do: path

  defp path_key(path, true) do
    if String.valid?(path),
      do: path |> String.normalize(:nfd) |> :string.casefold(),
      else: String.downcase(path, :ascii)
  end

  defp diff_paths(%{ignore_case?: true}, _roots), do: []
  defp diff_paths(git, roots), do: Enum.map(roots, &literal_path(git.prefix <> &1))
  defp literal_path(path), do: ":(top,literal)" <> path

  defp validate_root_directories(cd, roots) do
    case Enum.find(roots, &(not real_root?(Path.split(&1), cd))) do
      nil -> :ok
      root -> unavailable(:invalid_root_directory, :worktree, %{root: root})
    end
  end

  defp real_root?([], _dir), do: true

  defp real_root?([part | rest], dir) do
    path = Path.join(dir, part)
    match?({:ok, %{type: :directory}}, File.lstat(path)) and real_root?(rest, path)
  end

  defp git_context(opts) do
    cd = Keyword.get_lazy(opts, :cd, &File.cwd!/0)
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    with {:ok, cd} <- real_cd(cd),
         true <- is_integer(timeout) and timeout > 0 do
      env =
        System.get_env()
        |> Map.keys()
        |> Enum.filter(&String.starts_with?(&1, "GIT_"))
        |> Map.new(&{&1, nil})
        |> Map.merge(@git_env)

      git = %{cmd: Keyword.get(opts, :cmd, &System.cmd/3), cd: cd, env: env, timeout: timeout}

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
    resolve_directory(parts, root, 40)
  end

  defp real_cd(_cd), do: :error

  defp resolve_directory([], dir, _links), do: {:ok, dir}
  defp resolve_directory(["." | rest], dir, links), do: resolve_directory(rest, dir, links)

  defp resolve_directory([".." | rest], dir, links),
    do: resolve_directory(rest, Path.dirname(dir), links)

  defp resolve_directory([part | rest], dir, links) do
    path = Path.join(dir, part)

    case File.lstat(path) do
      {:ok, %{type: :directory}} ->
        resolve_directory(rest, path, links)

      {:ok, %{type: :symlink}} when links > 0 ->
        case File.read_link(path) do
          {:ok, target} ->
            [root | parts] = target |> Path.absname(dir) |> Path.split()
            resolve_directory(parts ++ rest, root, links - 1)

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

  defp require_worktree(git) do
    case command(git, ["rev-parse", "--is-inside-work-tree"], :worktree) do
      {:ok, "true\n"} -> :ok
      {:ok, _} -> unavailable(:not_inside_worktree, :worktree)
      error -> error
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

  defp command(git, args, step, limit \\ @metadata_bytes) do
    case run(git, args, step, limit) do
      {:ok, output, 0} -> {:ok, output}
      {:ok, _, status} -> unavailable(:git_exit, step, %{status: status})
      {:error, _, _} = error -> error
    end
  end

  defp run(git, args, step, limit) do
    opts = [cd: git.cd, env: git.env, into: %Output{limit: limit}, stderr_to_stdout: true]

    case timed_cmd(git, @git_options ++ args, opts) do
      :timeout ->
        unavailable(:timeout, step, %{timeout_ms: git.timeout})

      {"fatal: detected dubious ownership" <> _, status} when status != 0 ->
        checkout = git.env["GIT_WORK_TREE"] || git.cd
        command = "git config --global --add safe.directory " <> config_quote(checkout)

        unavailable(:dubious_ownership, step, %{
          status: status,
          hint: "Git refused #{inspect(checkout)}. Run as the owning user or run " <> command
        })

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
  end

  defp timed_cmd(git, args, opts) do
    task =
      Task.async(fn ->
        try do
          {:result, git.cmd.("git", args, opts)}
        catch
          kind, reason ->
            if reason == :git_output_limit, do: kill_child(self())
            {kind, reason, __STACKTRACE__}
        end
      end)

    case Task.yield(task, git.timeout) do
      {:ok, {:result, result}} ->
        result

      {:ok, {kind, reason, stacktrace}} ->
        :erlang.raise(kind, reason, stacktrace)

      nil ->
        kill_child(task.pid)
        Task.yield(task, to_timeout(millisecond: 100)) || Task.shutdown(task, :brutal_kill)
        :timeout
    end
  end

  # OTP starts each Unix port command in its own session and process group.
  defp kill_child(owner) do
    for port <- Port.list(),
        Port.info(port, :connected) == {:connected, owner},
        {:os_pid, pid} <- [Port.info(port, :os_pid)],
        is_integer(pid) do
      {program, args} =
        case :os.type() do
          {:win32, _} -> {"taskkill", ["/F", "/T", "/PID", Integer.to_string(pid)]}
          _ -> {"/bin/kill", ["-KILL", "--", Integer.to_string(-pid)]}
        end

      System.cmd(program, args, stderr_to_stdout: true)
    end
  end

  defp with_shallow({:error, reason, details}, shallow),
    do: {:error, reason, Map.put(details, :shallow, shallow)}

  defp with_shallow(result, _shallow), do: result

  defp unavailable(cause, step, details \\ %{}),
    do: {:error, :diff_unavailable, Map.merge(details, %{cause: cause, step: step})}

  defp empty_changes, do: %{files: %{}, renames: %{}, skipped: []}

  defp parse_diff("", _roots, _git), do: {:ok, empty_changes()}

  # Raw records include modes, while numstat identifies patch order. Git can
  # emit a binary numstat record for an unchanged file whose stat data changed.
  defp parse_diff(output, roots, git) do
    with [metadata, patch] <- :binary.split(output, <<0, 0>>),
         fields = :binary.split(metadata, <<0>>, [:global]),
         {:ok, raw, stats} <- raw_records(fields, %{}, @max_files),
         {:ok, records} <- stat_records(stats, raw, [], git) do
      patches(patch, records, roots, git, empty_changes())
    else
      {:error, _, _} = error -> error
      _ -> unavailable(:invalid_output, :diff)
    end
  end

  defp raw_records([":" <> _ | _], _, 0),
    do: unavailable(:file_limit, :diff, %{limit_files: @max_files})

  defp raw_records([":" <> _ = header, path | rest], records, remaining) do
    case {Regex.run(@raw_header, header, capture: :all_but_first), rest} do
      {[_, mode, old, _, "R"], [new_path | tail]} ->
        add_record(new_path, path, {"R", mode, old, false}, tail, records, remaining)

      {[old_mode, mode, old, object, status], _} when status != "R" ->
        stat_only? = status == "M" and mode == old_mode and String.trim(object, "0") == ""
        add_record(path, nil, {status, mode, old, stat_only?}, rest, records, remaining)

      _ ->
        unavailable(:invalid_output, :diff)
    end
  end

  defp raw_records(fields, records, _remaining), do: {:ok, records, fields}

  defp add_record(path, old_path, entry, rest, records, remaining) do
    if relative_path?(path) and (is_nil(old_path) or relative_path?(old_path)) do
      raw_records(rest, Map.put(records, {path, old_path}, entry), remaining - 1)
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
    git = %{git | cd: git.env["GIT_WORK_TREE"] || git.cd}

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
         {:ok, result} <- put_change(entry, ranges, binary?, roots, git.ignore_case?, result) do
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

  defp project_relative(path, %{prefix: prefix, ignore_case?: false}) do
    if String.starts_with?(path, prefix) do
      size = byte_size(prefix)
      binary_part(path, size, byte_size(path) - size)
    end
  end

  defp project_relative(path, %{prefix: prefix, ignore_case?: true}) do
    components = :binary.split(prefix, "/", [:global]) |> Enum.drop(-1)
    {directory, relative} = Enum.split(:binary.split(path, "/", [:global]), length(components))

    if relative != [] and
         path_key(Enum.join(directory, "/"), true) == path_key(Enum.join(components, "/"), true) do
      Enum.join(relative, "/")
    end
  end

  defp put_change({_path, _, "D", _}, _ranges, _binary?, _roots, _ignore_case?, result),
    do: {:ok, result}

  defp put_change({path, old_path, status, mode}, ranges, binary?, roots, ignore_case?, result) do
    relation = root_match(path, roots, ignore_case?)

    cond do
      relation != nil and (mode in ["120000", "160000"] or status == "T") ->
        result =
          if status == "R" and root_match(old_path, roots, ignore_case?) != nil,
            do: put_in(result.renames[path], old_path),
            else: result

        add_skipped(result, path, skip_reason(status, mode, binary?))

      relation == :below and String.ends_with?(path, ".ex") ->
        with {:ok, result} <- put_rename(result, path, old_path, status, roots, ignore_case?) do
          case skip_reason(status, mode, binary?) do
            nil when ranges == [] -> {:ok, result}
            nil -> {:ok, put_in(result.files[path], ranges)}
            reason -> add_skipped(result, path, reason)
          end
        end

      true ->
        {:ok, result}
    end
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
      ranges = if count == 0, do: ranges, else: [{from, from + count - 1} | ranges]
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

  defp validate_ranges(git, files) do
    Enum.reduce_while(files, :ok, fn {path, ranges}, :ok ->
      last_line = Enum.reduce(ranges, 0, fn {_from, to}, last -> max(to, last) end)

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
    def into(%{limit: limit}) do
      {{[], 0},
       fn
         {chunks, size}, {:cont, bytes} when size + byte_size(bytes) <= limit ->
           {[bytes | chunks], size + byte_size(bytes)}

         {_chunks, _size}, {:cont, _bytes} ->
           throw(:git_output_limit)

         {chunks, _size}, :done ->
           chunks |> Enum.reverse() |> IO.iodata_to_binary()

         _acc, :halt ->
           :ok
       end}
    end
  end
end
