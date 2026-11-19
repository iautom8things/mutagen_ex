defmodule MutagenEx.GitDiffIntegrationTest do
  use ExUnit.Case, async: true

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
    git!(repo, ~w(init --template= --initial-branch=main))
    git!(repo, ["config", "user.name", "GitDiff test"])
    git!(repo, ["config", "user.email", "gitdiff@example.invalid"])

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
