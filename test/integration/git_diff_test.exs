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
             %{path: "lib/sub.ex", reason: :gitlink},
             %{path: "lib/base_link.ex", reason: :preexisting_symlink},
             %{path: "lib/new_link.ex", reason: :preexisting_symlink},
             %{path: "lib/sub.ex", reason: :preexisting_gitlink}
           ]

    assert {:error, :diff_unavailable, %{cause: :base_symlink}} =
             GitDiff.base_file(base, "lib/base_link.ex", cd: repo)
  end

  @tag :tmp_dir
  @tag spec: "mutagen.git_diff.r8"
  test "preserves Git ownership checks and standard global safe.directory", %{tmp_dir: tmp} do
    outer = Path.join(tmp, "outer")
    repo = Path.join(outer, "repo")
    home = Path.join(tmp, "home")
    File.mkdir_p!(repo)
    File.mkdir!(home)
    init!(outer)
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
    assert hint =~ "git config --global --add safe.directory"
    assert hint =~ repo
    write!(home, ".gitconfig", safe_directories([repo]))

    assert {:error, :diff_unavailable,
            %{cause: :dubious_ownership, step: :enclosing_repository, hint: hint}} =
             GitDiff.changed_lines("HEAD", cd: repo, cmd: cmd)

    assert hint =~ inspect(outer)
    write!(home, ".gitconfig", safe_directories([repo | enclosing_checkouts(repo)]))

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
    git!(repo, ~w(config core.warnAmbiguousRefs false))

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

  @tag :tmp_dir
  @tag spec: "mutagen.git_diff.r1"
  test "skips directory symlinks and gitlinks under a source root", %{tmp_dir: repo} do
    init!(repo)
    write!(repo, "lib/regular.ex", "base\n")
    write!(repo, "other/hidden.ex", "other\n")
    commit!(repo, "Base")
    base = sha(repo)

    File.ln_s!("../other", Path.join(repo, "lib/sub"))
    git!(repo, ~w(add lib/sub))
    git!(repo, ["update-index", "--add", "--cacheinfo", "160000,#{base},lib/vendor"])
    File.mkdir!(Path.join(repo, "lib/vendor"))

    assert {:ok,
            %{
              files: %{},
              skipped: [
                %{path: "lib/sub", reason: :symlink},
                %{path: "lib/vendor", reason: :gitlink},
                %{path: "lib/sub", reason: :preexisting_symlink},
                %{path: "lib/vendor", reason: :preexisting_gitlink}
              ],
              warnings: []
            }} = GitDiff.changed_lines(base, cd: repo)
  end

  @tag :tmp_dir
  @tag spec: "mutagen.git_diff.r1"
  test "reports a gitlink at the root when the working directory is real", %{tmp_dir: repo} do
    init!(repo)
    write!(repo, "lib/regular.ex", "base\n")
    commit!(repo, "Base")
    base = sha(repo)
    git!(repo, ~w(rm -r lib))
    git!(repo, ["update-index", "--add", "--cacheinfo", "160000,#{base},lib"])
    File.mkdir!(Path.join(repo, "lib"))

    assert {:ok,
            %{
              skipped: [
                %{path: "lib", reason: :gitlink},
                %{path: "lib", reason: :preexisting_gitlink}
              ],
              warnings: []
            }} =
             GitDiff.changed_lines(base, cd: repo)
  end

  @tag :tmp_dir
  @tag spec: "mutagen.git_diff.r2"
  test "rejects a symlink at a source root or in its ancestry", %{tmp_dir: repo} do
    init!(repo)
    write!(repo, "lib/main.ex", "base\n")
    write!(repo, "apps/foo/lib/main.ex", "base\n")
    commit!(repo, "Base")
    base = sha(repo)
    File.rename!(Path.join(repo, "lib"), Path.join(repo, "other"))
    File.rename!(Path.join(repo, "apps/foo"), Path.join(repo, "moved"))
    File.ln_s!("other", Path.join(repo, "lib"))
    File.ln_s!("../moved", Path.join(repo, "apps/foo"))
    git!(repo, ~w(add --all))

    for root <- ["lib", "apps/foo/lib", "missing"] do
      assert {:error, :diff_unavailable, %{cause: :invalid_root_directory, root: ^root}} =
               GitDiff.changed_lines(base, cd: repo, roots: [root])
    end
  end

  @tag :tmp_dir
  @tag spec: "mutagen.git_diff.r2"
  test "includes a case-variant tracked path when Git configuration ignores case", %{
    tmp_dir: repo
  } do
    init!(repo)
    git!(repo, ~w(config core.ignorecase false))
    write!(repo, "lib/main.ex", "base\n")
    commit!(repo, "Base")
    base = sha(repo)
    write!(repo, "Lib/new.ex", "case variant\n")
    git!(repo, ~w(add -- Lib/new.ex))
    git!(repo, ["commit", "-m", "Case-variant path"])
    git!(repo, ~w(config core.ignorecase true))

    assert {:ok, %{files: %{"Lib/new.ex" => [{1, 1}]}}} =
             GitDiff.changed_lines(base, cd: repo)
  end

  @tag :tmp_dir
  @tag spec: "mutagen.git_diff.r2"
  test "resolves a symlinked project inside a different checkout", %{tmp_dir: tmp} do
    repo = Path.join(tmp, "repo")
    other = Path.join(tmp, "other")
    for dir <- [repo, other], do: File.mkdir!(dir)
    init!(repo)
    init!(other)
    write!(other, "lib/unrelated.ex", "other\n")
    commit!(other, "Other checkout")
    write!(repo, "apps/foo/lib/a.ex", "base\n")
    commit!(repo, "Base")
    base = sha(repo)
    write!(repo, "apps/foo/lib/a.ex", "changed\n")
    link = Path.join(other, "linked")
    File.ln_s!(Path.join(repo, "apps/foo"), link)

    assert {:ok, %{base: ^base, files: %{"lib/a.ex" => [{1, 1}]}}} =
             GitDiff.changed_lines(base, cd: link)

    assert GitDiff.base_file(base, "lib/a.ex", cd: link) == {:ok, "base\n"}
  end

  @tag :tmp_dir
  @tag spec: "mutagen.git_diff.r2"
  test "refuses a bare repository", %{tmp_dir: repo} do
    git!(repo, ~w(init --bare --template=))
    File.mkdir!(Path.join(repo, "lib"))

    assert {:error, :diff_unavailable, %{cause: :not_inside_worktree}} =
             GitDiff.changed_lines("HEAD", cd: repo)
  end

  @tag :tmp_dir
  @tag spec: "mutagen.git_diff.r6"
  test "distinguishes the zero object ID from a non-commit base", %{tmp_dir: repo} do
    init!(repo)
    write!(repo, "lib/a.ex", "base\n")
    commit!(repo, "Base")

    assert {:ok, "base\n"} = GitDiff.base_file(sha(repo), "lib/a.ex", cd: repo)

    for size <- [40, 64] do
      assert {:error, :diff_unavailable, %{cause: :zero_base_sha}} =
               GitDiff.base_file(String.duplicate("0", size), "lib/a.ex", cd: repo)
    end
  end

  @tag :tmp_dir
  @tag spec: "mutagen.git_diff.r8"
  test "timeout terminates descendants that could continue after Git exits", %{tmp_dir: repo} do
    init!(repo)
    write!(repo, "lib/a.ex", "base\n")
    commit!(repo, "Base")

    shim =
      write!(repo, "slow-git", """
      #!/bin/sh
      ( /bin/sleep 1; printf alive > escaped-child ) &
      wait
      """)

    File.chmod!(shim, 0o755)

    cmd = fn executable, args, opts ->
      if "diff" in args, do: System.cmd(shim, [], opts), else: System.cmd(executable, args, opts)
    end

    assert {:error, :diff_unavailable, %{cause: :timeout, step: :diff}} =
             GitDiff.changed_lines("HEAD", cd: repo, cmd: cmd, timeout: 500)

    Process.sleep(750)
    refute File.exists?(Path.join(repo, "escaped-child"))
  end

  describe "checkout boundaries" do
    @describetag :tmp_dir

    @tag spec: "mutagen.git_diff.r2"
    test "rejects a submodule at a parent of a source root", %{tmp_dir: tmp} do
      repo = submodule_fixture!(tmp)

      assert {:error, :diff_unavailable,
              %{cause: :nested_git_checkout, component: "apps/x", type: :regular}} =
               GitDiff.changed_lines("main", cd: repo, roots: ["apps/x/lib"])
    end

    @tag spec: "mutagen.git_diff.r2"
    test "rejects nested repositories whose .git entry is a directory", %{tmp_dir: repo} do
      init!(repo)
      write!(repo, "lib/a.ex", "base\n")
      commit!(repo, "Base")
      nested = Path.join(repo, "apps/local")
      File.mkdir_p!(nested)
      init!(nested)
      write!(nested, "lib/a.ex", "independent\n")
      commit!(nested, "Nested")

      assert {:error, :diff_unavailable,
              %{cause: :nested_git_checkout, component: "apps/local", type: :directory}} =
               GitDiff.changed_lines("HEAD", cd: repo, roots: ["apps/local/lib"])
    end

    @tag spec: "mutagen.git_diff.r2"
    test "rejects reads from inside a submodule checkout", %{tmp_dir: tmp} do
      checkout = Path.join(submodule_fixture!(tmp), "apps/x")
      base = sha(checkout)

      assert {:error, :diff_unavailable, %{cause: :inside_submodule, hint: hint}} =
               GitDiff.changed_lines("HEAD", cd: checkout)

      assert hint =~ "inside a submodule checkout is not supported"

      assert {:error, :diff_unavailable, %{cause: :inside_submodule}} =
               GitDiff.base_file(base, "lib/a.ex", cd: checkout)
    end

    @tag spec: "mutagen.git_diff.r2"
    test "rejects an absorbed submodule when Git cannot find its superproject", %{tmp_dir: tmp} do
      repo = submodule_fixture!(tmp)
      git!(repo, ~w(update-index --force-remove -- apps/x))
      checkout = Path.join(repo, "apps/x")

      assert git!(checkout, ~w(rev-parse --show-superproject-working-tree)) == ""
      assert git!(checkout, ~w(rev-parse --absolute-git-dir)) =~ "/modules/"

      assert {:error, :diff_unavailable, %{cause: :inside_submodule}} =
               GitDiff.changed_lines("HEAD", cd: checkout)
    end

    @tag spec: "mutagen.git_diff.r2"
    test "rejects an enclosing gitlink with a different case and normalization", %{tmp_dir: repo} do
      init!(repo)
      write!(repo, "lib/a.ex", "base\n")
      commit!(repo, "Base")
      base = sha(repo)
      checkout = Path.join(repo, "Apps/Café")
      File.mkdir_p!(checkout)
      init!(checkout)
      write!(checkout, "lib/a.ex", "nested\n")
      commit!(checkout, "Nested")
      tracked = String.normalize("apps/café", :nfd)
      git!(repo, ["update-index", "--add", "--cacheinfo", "160000,#{base},#{tracked}"])

      assert git!(checkout, ~w(rev-parse --show-superproject-working-tree)) == ""

      assert {:error, :diff_unavailable, %{cause: :inside_submodule}} =
               GitDiff.changed_lines("HEAD", cd: checkout)
    end

    @tag spec: "mutagen.git_diff.r2"
    test "rejects a project path that crosses a symlink inside the checkout", %{tmp_dir: repo} do
      init!(repo)
      write!(repo, "apps/other/lib/a.ex", "base\n")
      commit!(repo, "Base")
      link = Path.join(repo, "apps/foo")
      File.ln_s!("other", link)

      assert {:error, :diff_unavailable, %{cause: :symlinked_project_directory}} =
               GitDiff.changed_lines("HEAD", cd: link)

      assert {:error, :diff_unavailable, %{cause: :symlinked_project_directory}} =
               GitDiff.base_file(sha(repo), "lib/a.ex", cd: link)
    end

    @tag spec: "mutagen.git_diff.r2"
    test "rejects a project directory replaced by a committed link", %{tmp_dir: repo} do
      init!(repo)
      write!(repo, "apps/foo/lib/foo.ex", "base\n")
      write!(repo, "other/lib/evil.ex", "evil\n")
      commit!(repo, "Base")
      base = sha(repo)
      git!(repo, ~w(rm -r -q -- apps/foo))
      link = Path.join(repo, "apps/foo")
      File.mkdir_p!(Path.dirname(link))
      File.ln_s!("../other", link)
      commit!(repo, "Link project")

      for cd <- [link, Path.join(repo, "other")] do
        assert {:error, :diff_unavailable, %{cause: :symlinked_project_directory}} =
                 GitDiff.changed_lines(base, cd: cd)

        assert {:error, :diff_unavailable, %{cause: :symlinked_project_directory}} =
                 GitDiff.base_file(base, "lib/evil.ex", cd: cd)
      end
    end

    @tag spec: "mutagen.git_diff.r2"
    test "a checkout below a directory named modules and a link to its root still read", %{
      tmp_dir: tmp
    } do
      repo = Path.join(tmp, "modules/repo")
      File.mkdir_p!(repo)
      init!(repo)
      write!(repo, "lib/a.ex", "base\n")
      File.ln_s!(".", Path.join(repo, "self"))
      File.ln_s!("..", Path.join(repo, "lib/up"))
      commit!(repo, "Base")
      write!(repo, "lib/a.ex", "changed\n")

      assert {:ok, %{files: %{"lib/a.ex" => [{1, 1}]}, skipped: [%{path: "lib/up"}]}} =
               GitDiff.changed_lines("HEAD", cd: repo)
    end

    @tag spec: "mutagen.git_diff.r2"
    test "rejects a resolved project path targeted by a staged symlink", %{tmp_dir: repo} do
      init!(repo)
      write!(repo, "apps/foo/lib/a.ex", "base\n")
      commit!(repo, "Base")
      link = Path.join(repo, "alias")
      File.ln_s!("apps", link)
      git!(repo, ~w(add -- alias))
      File.rm!(link)
      project = Path.join(repo, "apps/foo")

      assert {:error, :diff_unavailable, %{cause: :symlinked_project_directory}} =
               GitDiff.changed_lines("HEAD", cd: project)

      assert {:error, :diff_unavailable, %{cause: :symlinked_project_directory}} =
               GitDiff.base_file(sha(repo), "lib/a.ex", cd: project)
    end

    @tag spec: "mutagen.git_diff.r1"
    test "reports unchanged index links when edits reach their targets", %{tmp_dir: repo} do
      init!(repo)
      write!(repo, "lib/regular.ex", "base\n")
      write!(repo, "other/o.ex", "base\n")
      commit!(repo, "Initial")
      initial = sha(repo)
      File.ln_s!("../other", Path.join(repo, "lib/sub"))
      File.ln_s!("../other/o.ex", Path.join(repo, "lib/o.ex"))
      git!(repo, ~w(add lib))
      git!(repo, ["update-index", "--add", "--cacheinfo", "160000,#{initial},lib/vendor"])
      File.mkdir!(Path.join(repo, "lib/vendor"))
      git!(repo, ["commit", "-m", "Track links"])
      base = sha(repo)
      write!(repo, "other/o.ex", "edited\n")
      write!(repo, "other/added.ex", "new code\n")
      git!(repo, ~w(add other))
      git!(repo, ["commit", "-m", "Edit targets"])

      assert {:ok,
              %{
                files: %{},
                warnings: [],
                skipped: [
                  %{path: "lib/o.ex", reason: :preexisting_symlink},
                  %{path: "lib/sub", reason: :preexisting_symlink},
                  %{path: "lib/vendor", reason: :preexisting_gitlink}
                ]
              }} = GitDiff.changed_lines(base, cd: repo)
    end

    @tag spec: "mutagen.git_diff.r2"
    test "uses disk case folding even when core.ignorecase is false", %{tmp_dir: repo} do
      init!(repo)
      git!(repo, ~w(config core.ignorecase false))
      write!(repo, "lib/a.ex", "base\n")
      commit!(repo, "Base")
      base = sha(repo)
      write!(repo, "Lib/new.ex", "case alias\n")
      git!(repo, ~w(add -- Lib/new.ex))
      git!(repo, ["commit", "-m", "Case variant"])

      original = File.stat!(Path.join(repo, "lib"))

      expected =
        case File.stat(Path.join(repo, "LIB")) do
          {:ok, %{inode: inode, major_device: device}}
          when inode == original.inode and device == original.major_device ->
            %{"Lib/new.ex" => [{1, 1}]}

          _ ->
            %{}
        end

      assert {:ok, %{files: ^expected}} = GitDiff.changed_lines(base, cd: repo)
    end

    @tag spec: "mutagen.git_diff.r2"
    test "folds a root with a dotless i when the disk ignores case", %{tmp_dir: repo} do
      assert_case_probe(repo, "", "lıb", "LıB", "LıB", "LıB/new.ex")
    end

    @tag spec: "mutagen.git_diff.r2"
    test "folds the project prefix when a nested root has no letters", %{tmp_dir: repo} do
      assert_case_probe(repo, "apps/foo", "123", "APPS/foo/123", "APPS/FOO/123", "123/new.ex")
    end

    @tag spec: "mutagen.git_diff.r2"
    test "folds a root without ASCII letters when the disk ignores case", %{tmp_dir: repo} do
      assert_case_probe(repo, "", "ü", "Ü", "Ü", "Ü/new.ex")
    end

    @tag spec: "mutagen.git_diff.r2"
    test "matches normalized roots in both Git case modes and keeps tracked spelling", %{
      tmp_dir: repo
    } do
      init!(repo)
      roots = ["café", "한"]
      for root <- roots, do: write!(repo, root <> "/base.ex", "base\n")
      commit!(repo, "Base")
      base = sha(repo)

      for root <- roots do
        path = String.normalize(root, :nfd) <> "/alias.ex"
        write!(repo, path, "normalized alias\n")
        git!(repo, ["-c", "core.precomposeunicode=false", "add", "--", path])
      end

      git!(repo, ["commit", "-m", "Normalized spelling"])

      for mode <- ["false", "true"], root <- roots do
        git!(repo, ["config", "core.ignorecase", mode])
        path = String.normalize(root, :nfd) <> "/alias.ex"

        assert {:ok, %{files: %{^path => [{1, 1}]}}} =
                 GitDiff.changed_lines(base, cd: repo, roots: [root])
      end
    end

    @tag spec: "mutagen.git_diff.r1"
    test "reads a rename across a root boundary as an addition", %{tmp_dir: repo} do
      init!(repo)
      write!(repo, "lib/base.ex", "base\n")
      write!(repo, "test/support/outside.ex", "first\nsecond\n")
      commit!(repo, "Base")
      base = sha(repo)
      git!(repo, ~w(mv test/support/outside.ex lib/moved.ex))

      assert_case_modes(repo, base, %{"lib/moved.ex" => [{1, 2}]})
    end

    @tag spec: "mutagen.git_diff.r1"
    test "reads a file that moved inside its replacement root directory as an add", %{
      tmp_dir: repo
    } do
      init!(repo)
      write!(repo, "src", "first\nsecond\n")
      commit!(repo, "File at future root")
      base = sha(repo)
      git!(repo, ~w(rm -- src))
      write!(repo, "src/x.ex", "first\nsecond\n")
      git!(repo, ~w(add -- src))

      assert git!(repo, ["diff", "--raw", "--find-renames", base]) =~ "R100\tsrc\tsrc/x.ex"

      assert {:ok, %{files: %{"src/x.ex" => [{1, 2}]}, renames: %{}}} =
               GitDiff.changed_lines(base, cd: repo, roots: ["src"])
    end

    @tag spec: "mutagen.git_diff.r5"
    test "unrelated paths with a drive-like prefix do not invalidate the inventory", %{
      tmp_dir: repo
    } do
      init!(repo)
      write!(repo, "a:b", "outside\n")
      write!(repo, "lib/a.ex", "base\n")
      commit!(repo, "Base")
      write!(repo, "lib/a.ex", "change\n")

      assert {:ok, %{files: %{"lib/a.ex" => [{1, 1}]}}} = GitDiff.changed_lines("HEAD", cd: repo)
    end

    @tag timeout: 180_000
    @tag spec: ["mutagen.git_diff.r4", "mutagen.git_diff.r5"]
    test "stale index stats do not consume the changed file cap or refresh the index", %{
      tmp_dir: repo
    } do
      init!(repo)
      File.mkdir!(Path.join(repo, "lib"))

      paths =
        for n <- 1..2_001 do
          path = Path.join(repo, "lib/#{n}.ex")
          File.write!(path, "unchanged\n")
          path
        end

      write!(repo, "lib/changed.ex", "base\n")
      commit!(repo, "Base")
      for path <- paths, do: File.touch!(path, {{2000, 1, 1}, {0, 0, 0}})
      write!(repo, "lib/changed.ex", "change\n")
      index = Path.join(repo, ".git/index")
      before = {File.stat!(index).mtime, File.read!(index)}

      assert {:ok, %{files: %{"lib/changed.ex" => [{1, 1}]}, skipped: []}} =
               GitDiff.changed_lines("HEAD", cd: repo)

      write!(repo, "lib/changed.ex", "base\n")

      assert {:ok, %{files: %{}, warnings: [:empty_diff]}} =
               GitDiff.changed_lines("HEAD", cd: repo)

      assert {File.stat!(index).mtime, File.read!(index)} == before
    end

    @tag spec: "mutagen.git_diff.r5"
    test "an out-of-root patch does not consume the output or file size cap", %{tmp_dir: repo} do
      init!(repo)
      write!(repo, "lib/a.ex", "base\n")
      commit!(repo, "Base")
      base = sha(repo)
      write!(repo, "lib/a.ex", "changed\n")
      write!(repo, "priv/large.bin", :binary.copy(<<0, 1, 2, 3>>, 5 * 1024 * 1024))
      git!(repo, ~w(add priv/large.bin))

      assert_case_modes(repo, base, %{"lib/a.ex" => [{1, 1}]})
    end

    @tag spec: "mutagen.git_diff.r5"
    test "out-of-root changes do not consume the changed file cap", %{tmp_dir: repo} do
      init!(repo)
      write!(repo, "lib/a.ex", "base\n")
      commit!(repo, "Base")
      base = sha(repo)
      write!(repo, "lib/a.ex", "changed\n")
      for n <- 1..2_001, do: write!(repo, "test/#{n}.exs", "outside\n")
      git!(repo, ~w(add test))

      assert_case_modes(repo, base, %{"lib/a.ex" => [{1, 1}]})
    end

    @tag spec: "mutagen.git_diff.r2"
    test "distinguishes an unchanged symlinked root and reports invalid component types", %{
      tmp_dir: repo
    } do
      init!(repo)
      write!(repo, "src/a.ex", "base\n")
      File.ln_s!("src", Path.join(repo, "lib"))
      commit!(repo, "Symlinked root")
      base = sha(repo)

      assert {:error, :diff_unavailable,
              %{cause: :preexisting_symlinked_root, root: "lib", component: "lib", type: :symlink}} =
               GitDiff.changed_lines(base, cd: repo)

      assert {:error, :diff_unavailable,
              %{
                cause: :invalid_root_directory,
                root: "src/a.ex/nested",
                component: "src/a.ex",
                type: :regular
              }} =
               GitDiff.changed_lines(base, cd: repo, roots: ["src/a.ex/nested"])
    end

    @tag spec: "mutagen.git_diff.r2"
    test "fails closed when a root is replaced while Git produces the diff", %{tmp_dir: repo} do
      init!(repo)
      write!(repo, "lib/a.ex", "base\n")
      commit!(repo, "Base")
      write!(repo, "lib/a.ex", "edit\n")

      cmd = fn executable, args, opts ->
        result = System.cmd(executable, args, opts)

        if "diff" in args do
          File.rename!(Path.join(repo, "lib"), Path.join(repo, "old-lib"))
          File.mkdir!(Path.join(repo, "lib"))
        end

        result
      end

      assert {:error, :diff_unavailable, %{cause: :root_changed}} =
               GitDiff.changed_lines("HEAD", cd: repo, cmd: cmd)
    end

    @tag spec: "mutagen.git_diff.r2"
    test "retries a directory entry change once and fails if it changes again", %{
      tmp_dir: repo
    } do
      init!(repo)
      write!(repo, "lib/a.ex", "base\n")
      commit!(repo, "Base")
      write!(repo, "lib/a.ex", "changed\n")
      root = Path.join(repo, "lib")
      save = Path.join(root, ".editor_save~")

      for changes <- [1, 2] do
        counter = :atomics.new(1, [])

        cmd =
          after_diff(fn ->
            attempt = :atomics.add_get(counter, 1, 1)

            cond do
              attempt > changes -> :ok
              File.exists?(save) -> File.rm!(save)
              true -> File.write!(save, "draft\n")
            end
          end)

        result = GitDiff.changed_lines("HEAD", cd: repo, cmd: cmd)

        if changes == 1 do
          assert {:ok, %{files: %{"lib/a.ex" => [{1, 1}]}}} = result
        else
          assert {:error, :diff_unavailable, %{cause: :root_changed}} = result
        end

        assert :atomics.get(counter, 1) == 2
      end
    end

    @tag spec: "mutagen.git_diff.r2"
    test "detects a directory swap below the root on a changed source path", %{tmp_dir: repo} do
      init!(repo)
      write!(repo, "lib/p/sub/a.ex", "base\n")
      commit!(repo, "Base")
      write!(repo, "lib/p/sub/a.ex", "changed\n")

      cmd =
        after_diff(fn ->
          File.rename!(Path.join(repo, "lib/p/sub"), Path.join(repo, "lib/p/old"))
          write!(repo, "lib/p/sub/a.ex", "changed\n")
        end)

      assert {:error, :diff_unavailable, %{cause: :root_changed, component: "lib/p/sub"}} =
               GitDiff.changed_lines("HEAD", cd: repo, cmd: cmd)
    end

    @tag spec: ["mutagen.git_diff.r2", "mutagen.git_diff.r8"]
    test "error paths in hints and details have no control characters", %{tmp_dir: tmp} do
      repo = Path.join(tmp, "checkout\u202Etext")
      File.mkdir!(repo)
      init!(repo)
      write!(repo, "lib/a.ex", "base\n")
      commit!(repo, "Base")

      assert {:error, :diff_unavailable,
              %{cause: :invalid_root_directory, root: "ab", component: "ab"}} =
               GitDiff.changed_lines("HEAD", cd: repo, roots: ["a\e\n\u2066\u200Bb"])

      home = Path.join(tmp, "isolated-home")
      File.mkdir!(home)

      cmd = fn executable, args, opts ->
        opts = opts |> put_command_env("HOME", home) |> put_command_env("XDG_CONFIG_HOME", home)
        opts = put_command_env(opts, "GIT_TEST_ASSUME_DIFFERENT_OWNER", "1")
        System.cmd(executable, args, opts)
      end

      assert {:error, :diff_unavailable, %{cause: :dubious_ownership, hint: hint}} =
               GitDiff.changed_lines("HEAD", cd: repo, cmd: cmd)

      refute Regex.match?(~r/[\p{Cc}\p{Cf}]/u, hint)
      assert hint =~ "checkouttext"
      refute hint =~ "git config"
    end

    @tag spec: "mutagen.git_diff.r8"
    test "a missing kill executable preserves the timeout error", %{tmp_dir: repo} do
      init!(repo)
      write!(repo, "lib/a.ex", "base\n")
      commit!(repo, "Base")

      cmd = fn executable, args, opts ->
        if "diff" in args,
          do: System.cmd("/bin/sleep", ["2"], opts),
          else: System.cmd(executable, args, opts)
      end

      kill_cmd = fn _executable, args, opts ->
        System.cmd(Path.join(repo, "absent-kill"), args, opts)
      end

      assert {:error, :diff_unavailable,
              %{cause: :timeout, step: :diff, child_may_still_run: true}} =
               GitDiff.changed_lines("HEAD", cd: repo, cmd: cmd, kill_cmd: kill_cmd, timeout: 500)
    end
  end

  defp submodule_fixture!(tmp) do
    source = Path.join(tmp, "source")
    repo = Path.join(tmp, "superproject")
    for dir <- [source, repo], do: File.mkdir!(dir)
    init!(source)
    init!(repo)
    write!(source, "lib/a.ex", "submodule source\n")
    commit!(source, "Source")
    write!(repo, "apps/x/lib/a.ex", "superproject source\n")
    commit!(repo, "Base")
    git!(repo, ~w(switch -c pr))
    git!(repo, ~w(rm -r apps/x))
    git!(repo, ["-c", "protocol.file.allow=always", "submodule", "add", "--", source, "apps/x"])
    git!(repo, ["commit", "-m", "Replace project with submodule"])
    repo
  end

  defp assert_case_modes(repo, base, expected) do
    for mode <- ["false", "true"] do
      git!(repo, ["config", "core.ignorecase", mode])
      assert {:ok, %{files: ^expected, renames: %{}}} = GitDiff.changed_lines(base, cd: repo)
    end
  end

  defp safe_directories(paths), do: Enum.map_join(paths, &"[safe]\n\tdirectory = #{&1}\n")

  defp enclosing_checkouts(dir) do
    parent = Path.dirname(dir)

    cond do
      parent == dir -> []
      File.exists?(Path.join(parent, ".git")) -> [parent | enclosing_checkouts(parent)]
      true -> enclosing_checkouts(parent)
    end
  end

  defp same_directory?(repo, first, second) do
    with {:ok, a} <- File.stat(Path.join(repo, first)),
         {:ok, b} <- File.stat(Path.join(repo, second)) do
      {a.major_device, a.minor_device, a.inode} == {b.major_device, b.minor_device, b.inode}
    else
      _ -> false
    end
  end

  defp assert_case_probe(repo, project, root, alias_path, probe, expected_path) do
    init!(repo)
    git!(repo, ~w(config core.ignorecase false))
    canonical = Path.join(project, root)
    write!(repo, Path.join(canonical, "base.ex"), "base\n")
    commit!(repo, "Base directory")
    base = sha(repo)
    path = Path.join(alias_path, "new.ex")
    write!(repo, path, "new\n")
    git!(repo, ["add", "--", path])
    git!(repo, ["commit", "-m", "Case variant"])

    expected =
      if same_directory?(repo, canonical, probe), do: %{expected_path => [{1, 1}]}, else: %{}

    assert {:ok, %{files: ^expected}} =
             GitDiff.changed_lines(base, cd: Path.join(repo, project), roots: [root])
  end

  defp after_diff(action) do
    fn executable, args, opts ->
      result = System.cmd(executable, args, opts)
      if "diff" in args, do: action.()
      result
    end
  end

  describe "read guards with real Git" do
    @describetag :tmp_dir

    setup %{tmp_dir: repo} do
      init!(repo)
      path = write!(repo, "lib/a.ex", "first\nold second\n")
      commit!(repo, "Base")
      %{repo: repo, path: path, base: sha(repo)}
    end

    @tag spec: "mutagen.git_diff.r7"
    test "Git has no system attributes source", %{repo: repo, base: base} do
      cmd =
        probe_diff(fn exec, flags, opts ->
          argv = flags ++ ~w(var GIT_ATTR_SYSTEM)
          # Git 2.41 supports the guard but does not expose this git-var query.
          control = System.cmd(exec, argv, put_command_env(opts, "GIT_ATTR_NOSYSTEM", "1"))
          assert System.cmd(exec, argv, opts) == control
        end)

      assert {:ok, _} = GitDiff.changed_lines(base, cd: repo, cmd: cmd)
    end

    @tag spec: "mutagen.git_diff.r1"
    test "reports an unrecognized mode in Git's diff response", %{
      repo: repo,
      path: path,
      base: base
    } do
      File.write!(path, "replacement\n")
      cmd = edit_git_output("diff", &:binary.replace(&1, ":100644 100644 ", ":100644 140000 "))

      assert {:ok, %{files: %{}, skipped: [%{path: "lib/a.ex", reason: :unsupported_mode}]}} =
               GitDiff.changed_lines(base, cd: repo, cmd: cmd)
    end

    @tag spec: "mutagen.git_diff.r6"
    test "refuses a tree entry where a regular base blob is required", %{repo: repo} do
      write!(repo, "lib/tree.ex/nested.ex", "source\n")
      commit!(repo, "Add directory")

      assert {:error, :diff_unavailable, %{cause: :not_a_regular_file}} =
               GitDiff.base_file(sha(repo), "lib/tree.ex", cd: repo)
    end

    @tag spec: "mutagen.git_diff.r6"
    test "rejects extra bytes on a successful Git blob read", %{repo: repo, base: base} do
      cmd = edit_git_output("show", &("warning: unexpected diagnostic\n" <> &1))

      assert {:error, :diff_unavailable, %{step: :base_file, cause: :invalid_output}} =
               GitDiff.base_file(base, "lib/a.ex", cd: repo, cmd: cmd)
    end

    @tag spec: "mutagen.git_diff.r5"
    test "refuses a repository with only a remote promisor setting", %{repo: repo, base: base} do
      git!(repo, ~w(config remote.origin.promisor true))

      assert {:error, :diff_unavailable, %{cause: :promisor_repository, hint: hint}} =
               GitDiff.changed_lines(base, cd: repo)

      assert hint =~ "full checkout"
    end

    @tag spec: "mutagen.git_diff.r1"
    test "bounds working-file reads even when Git emits a small patch", %{repo: repo, path: path} do
      File.open!(path, [:write, :binary], fn file ->
        IO.binwrite(file, "old\n")
        {:ok, _} = :file.position(file, 64 * 1024 * 1024)
        IO.binwrite(file, "\n")
      end)

      commit!(repo, "Large sparse source")
      File.open!(path, [:read, :write, :binary], &IO.binwrite(&1, "new\n"))

      assert {:error, :diff_unavailable, %{cause: :working_file_limit}} =
               GitDiff.changed_lines("HEAD", cd: repo)
    end

    @tag spec: "mutagen.git_diff.r7"
    test "Git's checkout conversion settings cannot change raw line ranges", %{
      repo: repo,
      path: path,
      base: base
    } do
      git!(repo, ~w(config core.autocrlf true))
      git!(repo, ~w(config core.safecrlf true))
      git!(repo, ~w(config core.eol crlf))
      File.write!(path, "first\r\nchanged second\r\n")

      assert {:ok, %{files: %{"lib/a.ex" => [{1, 2}]}}} =
               GitDiff.changed_lines(base, cd: repo)
    end

    @tag spec: "mutagen.git_diff.r1"
    test "rejects a changed line starting at zero in Git's diff response", %{
      repo: repo,
      path: path,
      base: base
    } do
      File.write!(path, "new first\nold second\n")
      cmd = edit_git_output("diff", &:binary.replace(&1, "+1 @@", "+0 @@"))

      assert {:error, :diff_unavailable, %{step: :diff, cause: :invalid_output}} =
               GitDiff.changed_lines(base, cd: repo, cmd: cmd)
    end

    @tag spec: "mutagen.git_diff.r7"
    test "Git's byte threshold does not reclassify small source as binary", %{
      repo: repo,
      path: path,
      base: base
    } do
      git!(repo, ~w(config core.bigFileThreshold 1))
      File.write!(path, "changed first line\nold second\n")
      git!(repo, ~w(add lib/a.ex))

      cmd =
        probe_diff(fn exec, flags, opts ->
          {output, 0} = System.cmd(exec, flags ++ ["diff", "--numstat", base, "--", "lib"], opts)
          assert output == "1\t1\tlib/a.ex\n"
        end)

      assert {:ok, %{files: %{"lib/a.ex" => [{1, 1}]}}} =
               GitDiff.changed_lines(base, cd: repo, cmd: cmd)
    end

    @tag spec: "mutagen.git_diff.r4"
    test "a Git status probe cannot refresh optional index data", %{
      repo: repo,
      path: path,
      base: base
    } do
      File.touch!(path, {{2001, 1, 1}, {0, 0, 0}})
      index = Path.join(repo, ".git/index")
      before = File.read!(index)

      cmd =
        probe_diff(fn exec, flags, opts ->
          assert {"", 0} =
                   System.cmd(exec, flags ++ ~w(status --porcelain --untracked-files=no), opts)
        end)

      assert {:ok, _} = GitDiff.changed_lines(base, cd: repo, cmd: cmd)
      assert File.read!(index) == before
    end

    @tag spec: "mutagen.git_diff.r4"
    test "an absent promisor blob cannot launch a lazy fetch", %{repo: repo, base: base} do
      remote = Path.join(repo, "remote.git")
      git!(repo, ["init", "--bare", "--template=", remote])
      partial = Path.join(repo, "partial")
      File.mkdir!(partial)
      init!(partial)
      git!(partial, ["remote", "add", "origin", remote])
      git!(partial, ~w(config remote.origin.promisor true))
      missing = String.duplicate("f", 40)

      cmd =
        probe_diff(fn exec, flags, opts ->
          opts = Keyword.put(opts, :cd, partial)
          argv = flags ++ ["cat-file", "-p", missing]
          # Older supported Git versions rely on promisor rejection.
          control = put_command_env(opts, "GIT_NO_LAZY_FETCH", "1")
          {output, status} = System.cmd(exec, argv, control)
          assert status != 0
          assert output =~ "Not a valid object name"
          assert System.cmd(exec, argv, opts) == {output, status}
        end)

      assert {:ok, _} = GitDiff.changed_lines(base, cd: repo, cmd: cmd)
    end

    @tag spec: "mutagen.git_diff.r4"
    test "Git denies file transport even when config allows it", %{repo: repo, base: base} do
      git!(repo, ~w(config protocol.file.allow always))

      cmd =
        probe_diff(fn exec, flags, opts ->
          {output, status} = System.cmd(exec, flags ++ ["ls-remote", repo], opts)
          assert status != 0
          assert output =~ "transport 'file' not allowed"
        end)

      assert {:ok, _} = GitDiff.changed_lines(base, cd: repo, cmd: cmd)
    end

    @tag spec: "mutagen.git_diff.r4"
    test "Git ignores the isolated system configuration file", %{repo: repo, base: base} do
      system = write!(repo, "system-config", "[roundthree]\nvalue = active\n")

      cmd =
        probe_diff(fn exec, flags, opts ->
          opts = put_command_env(opts, "GIT_CONFIG_SYSTEM", system)
          assert {"", 1} = System.cmd(exec, flags ++ ~w(config --get roundthree.value), opts)
        end)

      assert {:ok, _} = GitDiff.changed_lines(base, cd: repo, cmd: cmd)
    end

    @tag spec: "mutagen.git_diff.r4"
    test "the configured clean driver stays disabled even with attributes active", %{
      repo: repo,
      base: base
    } do
      write!(repo, ".gitattributes", "lib/a.ex filter=guard-probe\n")
      commit!(repo, "Assign clean driver")
      helper = write!(repo, "clean-probe", "#!/bin/sh\nprintf transformed\n")
      File.chmod!(helper, 0o755)
      git!(repo, ["config", "filter.guard-probe.clean", "./clean-probe"])
      attr_source = sha(repo)
      unfiltered = git!(repo, ~w(hash-object --no-filters lib/a.ex))

      cmd =
        probe_diff(fn exec, flags, opts ->
          opts = put_command_env(opts, "GIT_ATTR_SOURCE", attr_source)
          assert {^unfiltered, 0} = System.cmd(exec, flags ++ ~w(hash-object lib/a.ex), opts)
        end)

      assert {:ok, _} = GitDiff.changed_lines(base, cd: repo, cmd: cmd)
    end
  end

  defp edit_git_output(operation, edit) do
    fn executable, args, opts ->
      case System.cmd(executable, args, opts) do
        {output, 0} = result ->
          if operation in args, do: {edit.(output), 0}, else: result

        result ->
          result
      end
    end
  end

  defp probe_diff(probe) do
    fn executable, args, opts ->
      case Enum.split_while(args, &(&1 != "diff")) do
        {flags, ["diff" | _]} -> probe.(executable, flags, opts)
        _ -> :ok
      end

      System.cmd(executable, args, opts)
    end
  end

  defp put_command_env(opts, key, value),
    do: Keyword.update!(opts, :env, &Map.put(&1, key, value))

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
