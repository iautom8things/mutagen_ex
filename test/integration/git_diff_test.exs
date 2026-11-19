defmodule MutagenEx.GitDiffIntegrationTest do
  use ExUnit.Case, async: false

  alias MutagenEx.GitDiff

  @moduletag :git_diff_integration

  @tag :tmp_dir
  @tag spec: [
         "mutagen.git_diff.r1",
         "mutagen.git_diff.r2",
         "mutagen.git_diff.r4",
         "mutagen.git_diff.r6"
       ]
  test "reads the working-tree diff and base blobs without running Git helpers or writing", %{
    tmp_dir: repo
  } do
    init!(repo)

    original = Enum.map_join(1..12, "", &"line #{&1}\n")
    old = "lib/old café\t[1].ex"
    renamed = "lib/renamed\nfile.ex"

    write!(repo, old, original)
    write!(repo, "lib/pure old.ex", "pure rename\n")
    write!(repo, "lib/a_stat_only.ex", "unchanged content\n")
    write!(repo, "lib/work.ex", "first\nsecond\nthird\n")
    write!(repo, "lib/binary.ex", <<0, "before">>)
    write!(repo, "lib/mode.ex", "mode only\n")
    write!(repo, "lib/deleted.ex", "delete file\n")
    write!(repo, "lib/delete_line.ex", "keep\nremove this line\n")
    write!(repo, "test/outside.ex", "outside\n")
    write!(repo, "lib/unsupported.exs", "script\n")

    write!(repo, ".gitattributes", """
    lib/work.ex diff=hostile filter=one'shot=1
    lib/binary.ex diff=hostile filter=long-running
    """)

    git!(repo, ~w(add --all))
    git!(repo, ["commit", "-m", "Common ancestor"])
    base = sha(repo)

    write!(repo, "lib/main_only.ex", "main only\n")
    git!(repo, ~w(add --all))
    git!(repo, ["commit", "-m", "Advance main"])

    git!(repo, ["switch", "-c", "feature", base])
    write!(repo, "lib/committed.ex", "feature commit\n")
    git!(repo, ~w(add --all))
    git!(repo, ["commit", "-m", "Commit feature code"])
    head = sha(repo)

    git!(repo, ["mv", old, renamed])
    git!(repo, ["mv", "lib/pure old.ex", "lib/pure new.ex"])
    File.touch!(Path.join(repo, "lib/a_stat_only.ex"), {{2000, 1, 1}, {0, 0, 0}})
    write!(repo, renamed, String.replace(original, "line 6\n", "updated sixth line\n"))
    write!(repo, "lib/work.ex", "first\nchanged second line\nthird\n")
    write!(repo, "lib/binary.ex", <<0, "after">>)
    File.chmod!(Path.join(repo, "lib/mode.ex"), 0o755)
    File.rm!(Path.join(repo, "lib/deleted.ex"))
    write!(repo, "lib/delete_line.ex", "keep\n")
    write!(repo, "test/outside.ex", "outside work tree edit\n")
    write!(repo, "lib/unsupported.exs", "script work tree edit\n")
    write!(repo, "lib/intent.ex", "one\ntwo\n")
    git!(repo, ~w(add -N lib/intent.ex))
    write!(repo, "lib/untracked.ex", "invisible\n")

    helper = write!(repo, "helper.sh", "#!/bin/sh\nprintf 'ran\\n' > marker\nexit 1\n")
    File.chmod!(helper, 0o755)

    for {key, value} <- [
          {"diff.external", "./helper.sh"},
          {"diff.hostile.command", "./helper.sh"},
          {"diff.hostile.textconv", "./helper.sh"},
          {"diff.hostile.cachetextconv", "true"},
          {"diff.hostile.binary", "true"},
          {"diff.hostile.algorithm", "histogram"},
          {"filter.one'shot=1.clean", "./helper.sh"},
          {"filter.long-running.process", "./helper.sh"},
          {"filter.long-running.required", "true"},
          {"core.fsmonitor", "./helper.sh"},
          {"core.pager", "./helper.sh"},
          {"color.ui", "always"},
          {"diff.noprefix", "true"},
          {"diff.mnemonicPrefix", "true"},
          {"diff.context", "20"},
          {"diff.interHunkContext", "20"},
          {"diff.orderFile", "missing-order-file"}
        ] do
      git!(repo, ["config", key, value])
    end

    index = Path.join(repo, ".git/index")
    File.touch!(index, {{2000, 1, 1}, {0, 0, 0}})
    before = snapshot(repo)
    assert Map.has_key?(before, ".git/index")

    assert {:ok, %{base: ^base, head: ^head, files: files, renames: renames, warnings: []}} =
             GitDiff.changed_lines("main", cd: repo)

    assert files == %{
             renamed => [{6, 6}],
             "lib/committed.ex" => [{1, 1}],
             "lib/binary.ex" => [{1, 1}],
             "lib/intent.ex" => [{1, 2}],
             "lib/work.ex" => [{2, 2}]
           }

    assert renames == %{renamed => old, "lib/pure new.ex" => "lib/pure old.ex"}
    assert GitDiff.base_file(base, renames[renamed], cd: repo) == {:ok, original}
    assert GitDiff.base_file(base, renamed, cd: repo) == :absent
    assert GitDiff.base_file(base, "lib/intent.ex", cd: repo) == :absent
    assert GitDiff.base_file(base, "lib/binary.ex", cd: repo) == {:ok, <<0, "before">>}
    refute File.exists?(Path.join(repo, "marker"))
    assert snapshot(repo) == before
  end

  @tag :tmp_dir
  @tag spec: "mutagen.git_diff.r7"
  test "compares raw working lines regardless of committed and uncommitted attributes", %{
    tmp_dir: repo
  } do
    init!(repo)
    write!(repo, "lib/a.ex", "first\nold second\nthird\n")
    commit!(repo, "Base")
    base = sha(repo)

    for attribute <- ["-diff", "binary", "working-tree-encoding=UTF-16LE"] do
      write!(repo, ".gitattributes", "*.ex " <> attribute <> "\n")
      write!(repo, "lib/a.ex", "first\nchanged second\nthird\nfourth\n")

      assert {:ok, %{files: %{"lib/a.ex" => [{2, 2}, {4, 4}]}, skipped: []}} =
               GitDiff.changed_lines(base, cd: repo)

      git!(repo, ~w(add .gitattributes))
      git!(repo, ["commit", "-m", attribute])

      assert {:ok, %{files: %{"lib/a.ex" => [{2, 2}, {4, 4}]}, skipped: []}} =
               GitDiff.changed_lines(base, cd: repo)
    end

    write!(repo, ".git/info/attributes", "*.ex working-tree-encoding=UTF-16LE\n")

    assert {:error, :diff_unavailable, %{cause: :info_attributes}} =
             GitDiff.changed_lines(base, cd: repo)
  end

  @tag :tmp_dir
  @tag spec: ["mutagen.git_diff.r1", "mutagen.git_diff.r7"]
  test "reads NUL-containing source and ignores an unchanged touched binary before its patch", %{
    tmp_dir: repo
  } do
    init!(repo)
    binary = <<0, "logo">>
    logo = write!(repo, "lib/a_logo.png", binary)
    write!(repo, "lib/b.ex", "first\nold second\n")
    commit!(repo, "Base")
    base = sha(repo)

    File.touch!(logo, {{2000, 1, 1}, {0, 0, 0}})
    write!(repo, "lib/b.ex", <<"first\n# ", 0, " changed second\n">>)

    assert {:ok, %{files: %{"lib/b.ex" => [{2, 2}]}, skipped: [], warnings: []}} =
             GitDiff.changed_lines(base, cd: repo)
  end

  @tag :tmp_dir
  @tag spec: ["mutagen.git_diff.r2", "mutagen.git_diff.r6"]
  test "addresses roots, rename paths, and base blobs relative to the Mix project", %{
    tmp_dir: repo
  } do
    init!(repo)
    old = "apps/foo/lib/old.ex"
    new = "apps/foo/lib/new.ex"
    original = Enum.map_join(1..12, "", &"monorepo line #{&1}\n")
    write!(repo, old, original)
    write!(repo, "lib/top.ex", "top old\n")
    commit!(repo, "Base")
    base = sha(repo)
    git!(repo, ["mv", old, new])
    write!(repo, new, String.replace(original, "monorepo line 3\n", "an edited line\n"))
    write!(repo, "lib/top.ex", "top new\n")
    project = Path.join(repo, "apps/foo")

    assert {:ok, %{files: files, renames: %{"lib/new.ex" => "lib/old.ex"}}} =
             GitDiff.changed_lines(base, cd: project)

    assert files == %{"lib/new.ex" => [{3, 3}]}
    assert GitDiff.base_file(base, "lib/old.ex", cd: project) == {:ok, original}
    assert GitDiff.base_file(base, "lib/top.ex", cd: project) == :absent
  end

  @tag :tmp_dir
  @tag spec: ["mutagen.git_diff.r1", "mutagen.git_diff.r6"]
  test "reports symlinks, gitlinks, and type changes alongside regular edits", %{tmp_dir: repo} do
    init!(repo)
    write!(repo, "lib/change.ex", "before\n")
    write!(repo, "lib/edit.ex", "before\n")
    File.ln_s!("edit.ex", Path.join(repo, "lib/base_link.ex"))
    commit!(repo, "Base")
    base = sha(repo)
    File.rm!(Path.join(repo, "lib/change.ex"))
    File.ln_s!("edit.ex", Path.join(repo, "lib/change.ex"))
    File.ln_s!("edit.ex", Path.join(repo, "lib/new_link.ex"))
    git!(repo, ~w(add lib/new_link.ex))
    git!(repo, ["update-index", "--add", "--cacheinfo", "160000,#{base},lib/sub.ex"])
    File.mkdir!(Path.join(repo, "lib/sub.ex"))
    write!(repo, "lib/edit.ex", "changed\n")

    assert {:ok, %{files: files, skipped: skipped, warnings: []}} =
             GitDiff.changed_lines(base, cd: repo)

    assert files == %{"lib/edit.ex" => [{1, 1}]}

    assert skipped == [
             %{path: "lib/change.ex", reason: :type_change},
             %{path: "lib/new_link.ex", reason: :symlink},
             %{path: "lib/sub.ex", reason: :gitlink}
           ]

    assert {:error, :diff_unavailable, %{cause: :base_symlink}} =
             GitDiff.base_file(base, "lib/base_link.ex", cd: repo)
  end

  @tag :tmp_dir
  @tag spec: "mutagen.git_diff.r8"
  test "preserves Git ownership checks and standard global safe.directory", %{tmp_dir: tmp} do
    repo = Path.join(tmp, "repo")
    home = Path.join(tmp, "home")
    File.mkdir!(repo)
    File.mkdir!(home)
    init!(repo)
    write!(repo, "lib/a.ex", "before\n")
    commit!(repo, "Base")
    write!(repo, "lib/a.ex", "after\n")

    cmd = fn executable, args, opts ->
      env =
        Map.merge(opts[:env], %{
          "HOME" => home,
          "XDG_CONFIG_HOME" => home,
          "GIT_TEST_ASSUME_DIFFERENT_OWNER" => "1"
        })

      System.cmd(executable, args, Keyword.put(opts, :env, env))
    end

    assert {:error, :diff_unavailable, %{cause: :dubious_ownership, hint: hint}} =
             GitDiff.changed_lines("HEAD", cd: repo, cmd: cmd)

    assert hint =~ "owning user"
    assert hint =~ "safe.directory"
    write!(home, ".gitconfig", "[safe]\n\tdirectory = #{repo}\n")

    assert {:ok, %{files: %{"lib/a.ex" => [{1, 1}]}}} =
             GitDiff.changed_lines("HEAD", cd: repo, cmd: cmd)
  end

  @tag :tmp_dir
  @tag spec: "mutagen.git_diff.r4"
  test "ignores inherited Git overrides, replacement objects, grafts, and worktree redirects", %{
    tmp_dir: tmp
  } do
    repo = Path.join(tmp, "repo")
    other = Path.join(tmp, "other")
    for dir <- [repo, other], do: File.mkdir!(dir)
    init!(repo)
    init!(other)
    write!(other, "lib/a.ex", "wrong repository\n")
    commit!(other, "Wrong repository")

    original = "correct base\n"
    write!(repo, "lib/a.ex", original)
    commit!(repo, "Base")
    base = sha(repo)
    write!(repo, "lib/a.ex", "changed feature\n")
    commit!(repo, "Feature")
    head = sha(repo)
    write!(repo, "lib/a.ex", "replacement content\n")
    replacement = git!(repo, ~w(hash-object -w lib/a.ex)) |> String.trim()
    blob = git!(repo, ["rev-parse", base <> ":lib/a.ex"]) |> String.trim()
    git!(repo, ["replace", blob, replacement])
    write!(repo, "lib/a.ex", "changed feature\n")
    write!(other, "lib/a.ex", original)
    write!(repo, ".git/info/grafts", head <> "\n")
    git!(repo, ["config", "core.worktree", other])

    for {key, value} <- [
          {"GIT_DIR", Path.join(other, ".git")},
          {"GIT_INDEX_FILE", Path.join(other, ".git/index")}
        ] do
      previous = System.get_env(key)
      System.put_env(key, value)

      on_exit(fn ->
        if previous, do: System.put_env(key, previous), else: System.delete_env(key)
      end)
    end

    assert {:ok, %{base: ^base, head: ^head, files: %{"lib/a.ex" => [{1, 1}]}}} =
             GitDiff.changed_lines(base, cd: repo)

    assert GitDiff.base_file(base, "lib/a.ex", cd: repo) == {:ok, original}
  end

  @tag :tmp_dir
  @tag spec: "mutagen.git_diff.r3"
  test "rejects a tag shadowing a branch and accepts an explicit ref", %{tmp_dir: repo} do
    init!(repo)
    write!(repo, "lib/a.ex", "base\n")
    commit!(repo, "Base")
    git!(repo, ~w(switch -c feature))
    write!(repo, "lib/a.ex", "feature\n")
    commit!(repo, "Feature")
    git!(repo, ~w(tag main))

    assert {:error, :diff_unavailable, %{cause: :ambiguous_ref, hint: hint}} =
             GitDiff.changed_lines("main", cd: repo)

    assert hint =~ "full ref"

    git!(repo, ~w(update-ref refs/remotes/origin/main HEAD^))
    git!(repo, ~w(tag -am release v1 HEAD^))

    for ref <- ["refs/heads/main", "origin/main", "v1", "HEAD^", "HEAD~1"] do
      assert {:ok, %{files: %{"lib/a.ex" => [{1, 1}]}}} = GitDiff.changed_lines(ref, cd: repo)
    end
  end

  @tag :tmp_dir
  @tag spec: "mutagen.git_diff.r8"
  test "times out and kills a Git child that produces no output", %{tmp_dir: repo} do
    init!(repo)
    write!(repo, "lib/a.ex", "base\n")
    commit!(repo, "Base")

    shim =
      write!(repo, "slow-git", "#!/bin/sh\nprintf '%s' \"$$\" > child-pid\nexec /bin/sleep 4\n")

    File.chmod!(shim, 0o755)

    cmd = fn executable, args, opts ->
      if "diff" in args,
        do: System.cmd(shim, [], opts),
        else: System.cmd(executable, args, opts)
    end

    assert {:error, :diff_unavailable, %{cause: :timeout, step: :diff, timeout_ms: 500}} =
             GitDiff.changed_lines("HEAD", cd: repo, cmd: cmd, timeout: 500)

    pid = File.read!(Path.join(repo, "child-pid"))
    assert {_, 1} = System.cmd("/bin/kill", ["-0", pid], stderr_to_stdout: true)
  end

  @tag :tmp_dir
  @tag spec: ["mutagen.git_diff.r1", "mutagen.git_diff.r6"]
  test "rejects out-of-file ranges and a base ID that names a blob", %{tmp_dir: repo} do
    init!(repo)
    write!(repo, "lib/a.ex", "before\n")
    commit!(repo, "Base")
    blob = git!(repo, ["rev-parse", "HEAD:lib/a.ex"]) |> String.trim()
    write!(repo, "lib/a.ex", "after\n")

    cmd = fn executable, args, opts ->
      {output, status} = System.cmd(executable, args, opts)

      if "diff" in args,
        do: {:binary.replace(output, " +1 @@", " +999 @@"), status},
        else: {output, status}
    end

    assert {:error, :diff_unavailable, %{cause: :invalid_hunk_range}} =
             GitDiff.changed_lines("HEAD", cd: repo, cmd: cmd)

    assert {:error, :diff_unavailable, %{cause: :non_commit_base}} =
             GitDiff.base_file(blob, "lib/a.ex", cd: repo)
  end

  defp init!(repo) do
    git!(repo, ~w(init --template= --initial-branch=main))
    git!(repo, ["config", "user.name", "GitDiff test"])
    git!(repo, ["config", "user.email", "gitdiff@example.invalid"])
  end

  defp commit!(repo, message) do
    git!(repo, ~w(add --all))
    git!(repo, ["commit", "-m", message])
  end

  defp sha(repo), do: repo |> git!(~w(rev-parse HEAD)) |> String.trim()

  defp git!(repo, args) do
    {output, status} =
      System.cmd(
        "git",
        ["-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null" | args],
        cd: repo,
        env: %{"GIT_CONFIG_GLOBAL" => "/dev/null", "GIT_CONFIG_NOSYSTEM" => "1"},
        stderr_to_stdout: true
      )

    assert status == 0, "git #{inspect(args)} exited #{status}: #{output}"
    output
  end

  defp write!(repo, path, body) do
    target = Path.join(repo, path)
    File.mkdir_p!(Path.dirname(target))
    File.write!(target, body)
    target
  end

  defp snapshot(repo) do
    repo
    |> Path.join("**/*")
    |> Path.wildcard(match_dot: true)
    |> Map.new(fn path ->
      stat = File.stat!(path)
      content = if stat.type == :regular, do: File.read!(path)
      {Path.relative_to(path, repo), {stat.type, stat.mtime, content}}
    end)
  end
end
