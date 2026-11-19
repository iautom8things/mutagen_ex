defmodule MutagenEx.GitDiff do
  @moduledoc """
  Reads changed source lines against a Git merge-base and reads blobs from it.

  Git runs without a shell or pager. The environment drops inherited `GIT_*`
  variables, including `GIT_EXTERNAL_DIFF`, `GIT_DIFF_OPTS`, `GIT_PAGER`,
  `GIT_TRACE*`, `GIT_CONFIG*`, `GIT_DIR`, `GIT_WORK_TREE`, `GIT_INDEX_FILE`,
  `GIT_ATTR_SOURCE`, and `GIT_*_PATHSPECS`. `GIT_CONFIG_NOSYSTEM`,
  `GIT_CONFIG_GLOBAL`, and `GIT_ATTR_NOSYSTEM` suppress system and global
  configuration and attributes. `GIT_OPTIONAL_LOCKS`, `GIT_NO_REPLACE_OBJECTS`,
  `GIT_NO_LAZY_FETCH`, and `GIT_ALLOW_PROTOCOL` disable optional writes,
  replacement objects, lazy fetches, and transports. `LC_ALL` is set to `C`.

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
  and decorations.

  Local driver names are open-ended. A bounded config read finds
  `filter.<driver>.{clean,smudge,process,required}` and
  `diff.<driver>.{algorithm,binary,command,textconv,cacheTextconv}`.
  `GIT_CONFIG_PARAMETERS` carries Git's command-line config encoding for
  these keys. It disables the configured programs and pins the binary and
  algorithm settings without putting variable flags in argv.
  Built-in attributes and repository checkout rules such as line-ending
  conversion still apply. Repositories configured for promisor remotes fail
  closed so Git versions without the lazy-fetch switch cannot start a fetch.
  As with the index and worktree, keep the local config stable during the read.
  """

  defmodule Output do
    @moduledoc false
    defstruct [:limit]
  end

  @ref_pattern ~r/\A[A-Za-z0-9][A-Za-z0-9._\/@{}^~+-]{0,254}\z/
  @sha_pattern ~r/\A(?:[0-9a-fA-F]{40}|[0-9a-fA-F]{64})\z/
  @raw_header ~r/\A:([0-7]{6}) ([0-7]{6}) [0-9a-f]+ ([0-9a-f]+) ([AMDR])(?:[0-9]{1,3})?\z/
  @numstat ~r/\A(?:[0-9]+\t[0-9]+|-\t-)\t(.*)\z/s
  @hunk ~r/\A@@ -([0-9]{1,10})(?:,([0-9]{1,10}))? \+([0-9]{1,10})(?:,([0-9]{1,10}))? @@(?: .*)?\z/

  @max_diff_bytes 16 * 1024 * 1024
  @max_base_bytes 16 * 1024 * 1024
  @max_files 2_000
  @metadata_bytes 16 * 1024

  @git_config ~w(
    core.quotepath=off core.attributesFile=/dev/null core.bigFileThreshold=512m core.fsmonitor=
    core.hooksPath=/dev/null core.pager=cat pager.diff=false pager.show=false
    color.ui=false color.diff=false log.showSignature=false protocol.allow=never
    diff.external= diff.noPrefix=false diff.mnemonicPrefix=false
    diff.srcPrefix=a/ diff.dstPrefix=b/ diff.relative=false diff.context=0
    diff.interHunkContext=0 diff.algorithm=myers diff.indentHeuristic=true
    diff.suppressBlankEmpty=false diff.suppress-blank-empty=false
    diff.orderFile=/dev/null diff.renames=true diff.renameLimit=1000
    diff.ignoreSubmodules=all diff.submodule=short submodule.recurse=false
    diff.autoRefreshIndex=false
  )
  @git_options ["--no-pager" | Enum.flat_map(@git_config, &["-c", &1])]

  @safe_diff ~w(--no-ext-diff --no-textconv --no-color)
  @diff_flags @safe_diff ++
                ~w(--raw --numstat -z --patch --no-abbrev --unified=0 --find-renames --diff-filter=AMR
                   --src-prefix=a/ --dst-prefix=b/ --no-relative --ignore-submodules=all)
  @show_flags @safe_diff ++ ~w(--no-patch --no-notes --no-decorate --no-show-signature)

  @git_env %{
    "GIT_ALLOW_PROTOCOL" => ":",
    "GIT_ATTR_NOSYSTEM" => "1",
    "GIT_CONFIG_GLOBAL" => "/dev/null",
    "GIT_CONFIG_NOSYSTEM" => "1",
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
          warnings: [:empty_diff]
        }
  @type error :: {:error, :invalid_since_ref | :diff_unavailable, map()}

  @doc """
  Returns the new-side line ranges under `:roots` (default `["lib"]`).

  `:cd` selects the working directory. `:cmd` accepts a three-argument
  function with the same arguments and binary result as `System.cmd/3`.
  `:renames` maps each selected destination to its old path, including pure
  renames. Git detects renames within the selected roots.
  """
  @spec changed_lines(binary(), keyword()) :: {:ok, change_set()} | error()
  def changed_lines(ref, opts) do
    if valid_ref?(ref) do
      git = git_context(opts)

      with {:ok, roots} <- roots(opts),
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
    git = git_context(opts)

    with :ok <- validate_base_sha(base_sha),
         {:ok, roots} <- roots(opts),
         :ok <- validate_base_path(relative_path, roots),
         {:ok, shallow} <- shallow?(git) do
      git
      |> read_base_file(base_sha, relative_path)
      |> with_shallow(shallow)
    end
  end

  defp read_changes(git, ref, roots) do
    with {:ok, git} <- neutralize_drivers(git),
         {:ok, since} <- resolve_commit(git, ref, :resolve_ref, :unresolvable_ref),
         {:ok, head} <- resolve_commit(git, "HEAD", :resolve_head, :unresolvable_head),
         {:ok, base} <- merge_base(git, since, head),
         args = ["diff" | @diff_flags] ++ [base, "--" | Enum.map(roots, &literal_path/1)],
         {:ok, output} <- command(git, args, :diff, @max_diff_bytes),
         {:ok, changes} <- parse_diff(output, roots) do
      warnings = if map_size(changes.files) == 0, do: [:empty_diff], else: []
      {:ok, Map.merge(changes, %{base: base, head: head, warnings: warnings})}
    end
  end

  defp read_base_file(git, sha, path) do
    with {:ok, git} <- neutralize_drivers(git),
         {:ok, entry} <-
           command(
             git,
             ["ls-tree", "-z", "--full-tree", sha <> "^{commit}", "--", literal_path(path)],
             :base_tree
           ),
         :ok <- blob_entry(entry, path) do
      command(
        git,
        ["show" | @show_flags] ++ [sha <> ":" <> path, "--"],
        :base_file,
        @max_base_bytes
      )
    end
  end

  defp blob_entry("", _path), do: :absent

  defp blob_entry(entry, path) do
    entry_path = path <> <<0>>

    with [header, ^entry_path] <- :binary.split(entry, "\t"),
         [mode, type, sha] <- :binary.split(header, " ", [:global]),
         true <- Regex.match?(~r/\A[0-7]{6}\z/, mode) and valid_sha?(sha) do
      case type do
        "blob" -> :ok
        type when type in ["tree", "commit"] -> unavailable(:not_a_blob, :base_tree)
        _ -> unavailable(:invalid_output, :base_tree)
      end
    else
      _ -> unavailable(:invalid_output, :base_tree)
    end
  end

  defp valid_ref?(ref) do
    is_binary(ref) and byte_size(ref) <= 255 and Regex.match?(@ref_pattern, ref) and
      :binary.match(ref, "..") == :nomatch
  end

  defp valid_sha?(sha) do
    is_binary(sha) and byte_size(sha) in [40, 64] and Regex.match?(@sha_pattern, sha)
  end

  defp validate_base_sha(sha) do
    if valid_sha?(sha), do: :ok, else: unavailable(:invalid_base_sha, :base_file)
  end

  defp validate_base_path(path, roots) do
    if relative_path?(path) and in_roots?(path, roots),
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

  defp in_roots?(path, roots), do: Enum.any?(roots, &String.starts_with?(path, &1 <> "/"))
  defp literal_path(path), do: ":(top,literal)" <> path

  defp git_context(opts) do
    env =
      System.get_env()
      |> Map.keys()
      |> Enum.filter(&String.starts_with?(&1, "GIT_"))
      |> Map.new(&{&1, nil})
      |> Map.merge(@git_env)

    {Keyword.get(opts, :cmd, &system_cmd/3),
     [cd: Keyword.get_lazy(opts, :cd, &File.cwd!/0), env: env]}
  end

  # The task owns the port, so aborting collection closes it on task exit.
  defp system_cmd(executable, args, opts) do
    task =
      Task.async(fn ->
        try do
          {:ok, System.cmd(executable, args, opts)}
        catch
          kind, reason -> {kind, reason, __STACKTRACE__}
        end
      end)

    case Task.await(task, :infinity) do
      {:ok, result} -> result
      {kind, reason, stacktrace} -> :erlang.raise(kind, reason, stacktrace)
    end
  end

  defp shallow?(git) do
    case run(git, ["rev-parse", "--is-shallow-repository"], :repository, @metadata_bytes, true) do
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

  defp neutralize_drivers({cmd, opts} = git) do
    args = ["config", "--null", "--name-only", "--get-regexp", @config_query]

    case run(git, args, :config, @metadata_bytes) do
      {:ok, "", 1} ->
        {:ok, git}

      {:ok, output, 0} ->
        with {:ok, parameters} <- driver_overrides(output) do
          {:ok,
           {cmd, Keyword.update!(opts, :env, &Map.put(&1, "GIT_CONFIG_PARAMETERS", parameters))}}
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

  defp driver_value("extensions.partialclone"), do: unavailable(:promisor_repository, :config)
  defp driver_value("remote." <> _), do: unavailable(:promisor_repository, :config)

  defp driver_value(key) do
    with true <- String.valid?(key),
         [section, setting] <- Regex.run(@driver_pattern, key, capture: :all_but_first),
         {:ok, value} <- Map.fetch(@driver_keys[section], setting) do
      {:ok, value}
    else
      _ -> unavailable(:invalid_output, :config)
    end
  end

  defp command(git, args, step, limit \\ @metadata_bytes) do
    case run(git, args, step, limit) do
      {:ok, output, 0} -> {:ok, output}
      {:ok, _, status} -> unavailable(:git_exit, step, %{status: status})
      {:error, _, _} = error -> error
    end
  end

  defp run({cmd, opts}, args, step, limit, capture_error? \\ false) do
    opts = opts ++ [into: %Output{limit: limit}, stderr_to_stdout: capture_error?]

    case cmd.("git", @git_options ++ args, opts) do
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
        reason -> unavailable(:git_start_failed, step, %{os_error: inspect(reason)})
      end
  catch
    :git_output_limit -> unavailable(:output_limit, step, %{limit_bytes: limit})
  end

  defp with_shallow({:error, reason, details}, shallow),
    do: {:error, reason, Map.put(details, :shallow, shallow)}

  defp with_shallow(result, _shallow), do: result

  defp unavailable(cause, step, details \\ %{}),
    do: {:error, :diff_unavailable, Map.merge(details, %{cause: cause, step: step})}

  defp parse_diff("", _roots), do: {:ok, %{files: %{}, renames: %{}}}

  # Raw records include modes. Numstat records identify which of those files
  # actually have a patch, since a raw modification can be a stat-only change.
  defp parse_diff(output, roots) do
    with [metadata, patch] <- :binary.split(output, <<0, 0>>),
         fields = :binary.split(metadata, <<0>>, [:global]),
         {:ok, raw, stats} <- raw_records(fields, %{}, @max_files),
         {:ok, records} <- stat_records(stats, raw, []) do
      patches(patch, records, roots, %{files: %{}, renames: %{}})
    else
      {:error, _, _} = error -> error
      _ -> unavailable(:invalid_output, :diff)
    end
  end

  defp raw_records([":" <> _ | _], _, 0),
    do: unavailable(:file_limit, :diff, %{limit_files: @max_files})

  defp raw_records([":" <> _ = header, path | rest], records, remaining) do
    case Regex.run(@raw_header, header, capture: :all_but_first) do
      [_, mode, _, "R"] ->
        case rest do
          [new_path | tail] ->
            add_record(new_path, path, {mode, false}, tail, records, remaining)

          [] ->
            unavailable(:invalid_output, :diff)
        end

      [old_mode, mode, object, status] ->
        stat_only? = status == "M" and mode == old_mode and String.trim(object, "0") == ""
        add_record(path, nil, {mode, stat_only?}, rest, records, remaining)

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

  defp stat_records([], raw, records) do
    if Enum.all?(raw, fn {_, {_mode, stat_only?}} -> stat_only? end),
      do: {:ok, Enum.reverse(records)},
      else: unavailable(:invalid_output, :diff)
  end

  defp stat_records([header | rest], raw, records) do
    case {Regex.run(@numstat, header, capture: :all_but_first), rest} do
      {[""], [old_path, path | tail]} -> add_stat(path, old_path, tail, raw, records)
      {[path], _} when path != "" -> add_stat(path, nil, rest, raw, records)
      _ -> unavailable(:invalid_output, :diff)
    end
  end

  defp add_stat(path, old_path, rest, raw, records) do
    case Map.pop(raw, {path, old_path}) do
      {{mode, _}, raw} -> stat_records(rest, raw, [{path, old_path, mode} | records])
      {nil, _} -> unavailable(:invalid_output, :diff)
    end
  end

  defp patches("", [], _roots, result), do: {:ok, result}

  defp patches("diff --git " <> section, [record | records], roots, result) do
    with [_paths, body] <- :binary.split(section, "\n"),
         {:ok, ranges, rest} <- hunks(body, []),
         {:ok, result} <- put_change(record, ranges, roots, result) do
      patches(rest, records, roots, result)
    else
      {:error, _, _} = error -> error
      _ -> unavailable(:invalid_output, :diff)
    end
  end

  defp patches(_, _, _, _), do: unavailable(:invalid_output, :diff)

  defp put_change({path, old_path, mode}, ranges, roots, result) do
    if mode in ["100644", "100755"] and in_roots?(path, roots) and String.ends_with?(path, ".ex") do
      with {:ok, result} <- put_rename(result, path, old_path, roots) do
        case ranges do
          [] -> {:ok, result}
          _ -> {:ok, put_in(result.files[path], ranges)}
        end
      end
    else
      {:ok, result}
    end
  end

  defp put_rename(result, _path, nil, _roots), do: {:ok, result}

  defp put_rename(result, path, old_path, roots) do
    if in_roots?(old_path, roots),
      do: {:ok, put_in(result.renames[path], old_path)},
      else: unavailable(:invalid_path, :diff)
  end

  defp hunks("", ranges), do: {:ok, Enum.reverse(ranges), ""}
  defp hunks("diff --git " <> _ = rest, ranges), do: {:ok, Enum.reverse(ranges), rest}

  defp hunks(patch, ranges) do
    case :binary.split(patch, "\n") do
      ["@@" <> _ = line, rest] ->
        read_hunk(line, rest, ranges)

      [line, rest] ->
        if patch_metadata?(line),
          do: hunks(rest, ranges),
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
      "rename to ",
      "Binary files "
    ]) or line == "\\ No newline at end of file"
  end

  defp read_hunk(line, rest, ranges) do
    with [old_from, old_count, from, count] <- Regex.run(@hunk, line, capture: [1, 2, 3, 4]),
         {old_from, old_count} <- parse_range(old_from, old_count),
         {from, count} <- parse_range(from, count),
         true <- (old_from > 0 or old_count == 0) and (from > 0 or count == 0),
         {:ok, rest} <- hunk_body(rest, old_count, count) do
      ranges = if count == 0, do: ranges, else: [{from, from + count - 1} | ranges]
      hunks(rest, ranges)
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
