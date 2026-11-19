defmodule MutagenEx.GitDiffTest do
  use ExUnit.Case, async: true

  alias MutagenEx.GitDiff

  @since String.duplicate("a", 40)
  @head String.duplicate("b", 40)
  @base String.duplicate("c", 40)
  @ref "refs/heads/main"
  @diff_flags ~w(diff --no-ext-diff --no-textconv --no-color --raw --numstat -z --patch --no-abbrev
                 --unified=0 --find-renames --diff-filter=AMR --src-prefix=a/ --dst-prefix=b/
                 --no-relative --ignore-submodules=all)

  @tag spec: "mutagen.git_diff.r1"
  test "takes only the new side of each hunk" do
    output =
      diff([
        {"M", ["lib/sample.ex"], "100644",
         """
         --- a/lib/sample.ex
         +++ b/lib/sample.ex
         @@ -10 +12 @@ def first
         -old
         +new
         @@ -20 +21,0 @@
         -deleted
         @@ -31,0 +34,3 @@
         +a
         +++ b/not_a_file_header
         +@@ -4 +5 @@
         """},
        {"M", ["lib/deletions.ex"], "100644", "@@ -13 +12,0 @@\n-deleted\n"}
      ])

    assert {:ok,
            %{
              base: @base,
              head: @head,
              files: %{"lib/sample.ex" => [{12, 12}, {34, 36}]},
              renames: %{},
              warnings: []
            }} = changed(output)
  end

  @tag spec: ["mutagen.git_diff.r1", "mutagen.git_diff.r2"]
  test "keys hunks and pure or edited renames by NUL-delimited destination paths" do
    pure_old = "lib/old café.ex"
    pure_new = "lib/pure move.ex"
    edited_old = "lib/old\tname.ex"
    edited_new = "lib/new\nname.ex"
    raw_path = <<"lib/raw_", 255, ".ex">>

    output =
      diff([
        {"R100", [pure_old, pure_new], "100644",
         "similarity index 100%\nrename from old café.ex\nrename to pure move.ex\n"},
        {"R083", [edited_old, edited_new], "100644",
         "similarity index 83%\nrename from \"old\\tname.ex\"\nrename to \"new\\nname.ex\"\n" <>
           "@@ -12 +12,3 @@\n-a\n+b\n+c\n+d\n"},
        {"A", [raw_path], "100644",
         "new file mode 100644\n@@ -0,0 +1 @@\n+single line\n\\ No newline at end of file\n"}
      ])

    assert {:ok, %{files: files, renames: renames}} = changed(output)
    assert files == %{edited_new => [{12, 14}], raw_path => [{1, 1}]}
    assert renames == %{pure_new => pure_old, edited_new => edited_old}
  end

  @tag spec: "mutagen.git_diff.r1"
  test "skips deletes, binary files, file mode changes, symlinks and other files" do
    insertion = "@@ -0,0 +1 @@\n+new\n"

    output =
      diff([
        {"D", ["lib/deleted.ex"], "000000", "deleted file mode 100644\n@@ -1 +0,0 @@\n-old\n"},
        {"M", ["lib/binary.ex"], "100644",
         "Binary files a/lib/binary.ex and b/lib/binary.ex differ\n"},
        {"M", ["lib/mode.ex"], "100755", "old mode 100644\nnew mode 100755\n"},
        {"A", ["lib/link.ex"], "120000", insertion},
        {"A", ["lib/file.exs"], "100644", insertion},
        {"A", ["test/file.ex"], "100644", insertion},
        {"A", ["library/file.ex"], "100644", insertion}
      ])

    for patch <- [output, ""] do
      assert {:ok, %{files: files, renames: renames, warnings: [:empty_diff]}} = changed(patch)
      assert files == %{}
      assert renames == %{}
    end
  end

  @tag spec: ["mutagen.git_diff.r1", "mutagen.git_diff.r3"]
  test "uses configurable literal roots" do
    insertion = "@@ -0,0 +1 @@\n+new\n"

    output =
      diff([
        {"A", ["apps/[scope]/lib/in.ex"], "100644", insertion},
        {"A", ["extra/other.ex"], "100644", insertion},
        {"A", ["lib/out.ex"], "100644", insertion}
      ])

    cmd =
      runner(%{diff: {output, 0}}, fn
        ["diff" | _] = args, _opts ->
          assert Enum.take(args, -3) == [
                   "--",
                   ":(top,literal)apps/[scope]/lib",
                   ":(top,literal)extra"
                 ]

        _args, _opts ->
          :ok
      end)

    assert {:ok, %{files: files}} =
             GitDiff.changed_lines(@ref, cmd: cmd, roots: ["apps/[scope]/lib", "extra"])

    assert files == %{"apps/[scope]/lib/in.ex" => [{1, 1}], "extra/other.ex" => [{1, 1}]}
  end

  @tag spec: "mutagen.git_diff.r2"
  test "rejects unsafe Git paths, including the source of a rename" do
    for {status, paths} <- [
          {"M", ["/lib/absolute.ex"]},
          {"M", ["lib/../escape.ex"]},
          {"R100", ["lib/../old.ex", "lib/new.ex"]},
          {"R100", ["outside/old.ex", "lib/new.ex"]}
        ] do
      output = diff([{status, paths, "100644", ""}])
      assert {:error, :diff_unavailable, %{step: :diff, cause: :invalid_path}} = changed(output)
    end
  end

  @tag spec: "mutagen.git_diff.r3"
  test "rejects unsafe refs without invoking Git" do
    for ref <- [
          "--output=/tmp/x",
          "-h",
          "HEAD;rm -rf",
          "a..b",
          "@{-1}",
          "HEAD\n",
          String.duplicate("a", 300)
        ] do
      assert {:error, :invalid_since_ref, %{cause: :invalid_ref}} =
               GitDiff.changed_lines(ref, cmd: &unexpected_command/3)
    end
  end

  @tag spec: "mutagen.git_diff.r3"
  test "keeps the ref in one verification argument and uses only validated SHAs afterward" do
    config = "filter.Example.clean\0diff.Example.textconv\0"

    fake = runner(%{config: {config, 0}})

    cmd = fn "git", argv, opts ->
      args = git_args(argv)
      send(self(), {:git, args, opts})
      send(self(), {:git_prefix, Enum.take(argv, length(argv) - length(args))})
      fake.("git", argv, opts)
    end

    assert {:ok, _} = GitDiff.changed_lines(@ref, cmd: cmd)
    assert_received {:git, ["rev-parse", "--is-shallow-repository"], _}
    assert_received {:git, ["config", "--null", "--name-only", "--get-regexp", _], _}

    assert_received {:git,
                     [
                       "rev-parse",
                       "--verify",
                       "--quiet",
                       "--end-of-options",
                       "refs/heads/main^{commit}"
                     ], _}

    assert_received {:git,
                     ["rev-parse", "--verify", "--quiet", "--end-of-options", "HEAD^{commit}"], _}

    assert_received {:git, ["merge-base", @since, @head], _}
    diff_args = @diff_flags ++ [@base, "--", ":(top,literal)lib"]
    assert_received {:git, ^diff_args, opts}
    refute_received {:git, _, _}

    assert_received {:git_prefix, ["--no-pager" | _] = prefix}
    assert "core.quotepath=off" in prefix
    assert "core.fsmonitor=" in prefix
    assert "diff.external=" in prefix
    assert "diff.noPrefix=false" in prefix

    for _ <- 1..5, do: assert_received({:git_prefix, ^prefix})
    refute_received {:git_prefix, _}

    assert %{
             "GIT_CONFIG_PARAMETERS" => "'filter.Example.clean'='' 'diff.Example.textconv'=''",
             "GIT_OPTIONAL_LOCKS" => "0",
             "GIT_CONFIG_NOSYSTEM" => "1",
             "GIT_CONFIG_GLOBAL" => "/dev/null",
             "GIT_NO_LAZY_FETCH" => "1",
             "GIT_ALLOW_PROTOCOL" => ":"
           } = opts[:env]
  end

  @tag spec: "mutagen.git_diff.r5"
  test "reports shallow history with a fetch-depth hint and stops there" do
    cmd = fn "git", args, _opts ->
      assert git_args(args) == ["rev-parse", "--is-shallow-repository"]
      {"true\n", 0}
    end

    assert {:error, :diff_unavailable, %{shallow: true, hint: hint, cause: :shallow_repository}} =
             GitDiff.changed_lines(@ref, cmd: cmd)

    assert hint =~ "fetch-depth: 0"
  end

  @tag spec: "mutagen.git_diff.r5"
  test "distinguishes repository, Git executable, revision, and command failures" do
    cmd = fn "git", _args, _opts -> :erlang.error(:enoent) end

    assert {:error, :diff_unavailable, %{cause: :git_not_installed, step: :repository}} =
             GitDiff.changed_lines(@ref, cmd: cmd)

    for {step, output, cause} <- [
          {:repository, {"fatal: not a git repository (or any parent)\n", 128},
           :not_a_git_repository},
          {:resolve_ref, {"", 1}, :unresolvable_ref},
          {:resolve_head, {"", 1}, :unresolvable_head},
          {:merge_base, {"", 1}, :no_merge_base},
          {:diff, {"partial output", 128}, :git_exit},
          {:config, {"extensions.partialclone\0", 0}, :promisor_repository}
        ] do
      cmd = runner(%{step => output})

      assert {:error, :diff_unavailable, %{cause: ^cause, step: ^step} = details} =
               GitDiff.changed_lines(@ref, cmd: cmd)

      if step != :repository, do: assert(details.shallow == false)
    end
  end

  @tag spec: ["mutagen.git_diff.r3", "mutagen.git_diff.r5"]
  test "fails closed on malformed SHAs and patches" do
    for {step, output} <- [
          {:resolve_ref, "-h\n"},
          {:resolve_head, @head <> "\nmore\n"},
          {:merge_base, "abc\n"},
          {:diff, "not a diff"},
          {:diff, ":100644 100644 a b M\0lib/file.ex\0\0"},
          {:diff, diff([{"M", ["lib/file.ex"], "100644", "@@ -1 +oops @@\n"}])},
          {:diff, diff([{"M", ["lib/file.ex"], "100644", "@@ -1 +1,3 @@\n-a\n+b\n"}])}
        ] do
      cmd =
        runner(%{step => {output, 0}}, fn args, _opts ->
          assert step_for(args) in steps_through(step)
        end)

      assert {:error, :diff_unavailable, %{cause: :invalid_output, step: ^step}} =
               GitDiff.changed_lines(@ref, cmd: cmd)
    end
  end

  @tag spec: "mutagen.git_diff.r5"
  test "bounds output during collection and checks the file count" do
    limit = 16 * 1024 * 1024
    chunk = :binary.copy("x", limit)

    cmd =
      runner(%{}, fn
        ["diff" | _], opts ->
          {initial, collect} = Collectable.into(opts[:into])
          acc = collect.(initial, {:cont, chunk})
          collect.(acc, {:cont, "x"})
          flunk("diff collector accepted output over the limit")

        _args, _opts ->
          :ok
      end)

    assert {:error, :diff_unavailable, %{cause: :output_limit, limit_bytes: ^limit}} =
             GitDiff.changed_lines(@ref, cmd: cmd)

    records = for n <- 1..2_001, do: {"M", ["lib/#{n}.ex"], "100644", ""}

    assert {:error, :diff_unavailable, %{cause: :file_limit, limit_files: 2_000}} =
             changed(diff(records))
  end

  @tag spec: ["mutagen.git_diff.r3", "mutagen.git_diff.r6"]
  test "reads exact base bytes and distinguishes an absent path from a command failure" do
    path = "lib/old café\twith\nlines[1].ex"
    content = <<"old\r\n", 0, 255>>
    entry = "100644 blob " <> @since <> "\t" <> path <> <<0>>

    cmd =
      runner(%{base_tree: {entry, 0}, base_file: {content, 0}}, fn
        ["ls-tree" | _] = args, _opts ->
          assert args == [
                   "ls-tree",
                   "-z",
                   "--full-tree",
                   @base <> "^{commit}",
                   "--",
                   ":(top,literal)" <> path
                 ]

        ["show" | _] = args, _opts ->
          assert args == ~w(show --no-ext-diff --no-textconv --no-color --no-patch --no-notes
                          --no-decorate --no-show-signature) ++ [@base <> ":" <> path, "--"]

        _args, _opts ->
          :ok
      end)

    assert GitDiff.base_file(@base, path, cmd: cmd) == {:ok, content}

    absent =
      runner(%{base_tree: {"", 0}}, fn args, _opts ->
        refute match?(["show" | _], args)
      end)

    assert GitDiff.base_file(@base, path, cmd: absent) == :absent
    failed = runner(%{base_tree: {"", 128}})

    assert {:error, :diff_unavailable, %{step: :base_tree, cause: :git_exit, status: 128}} =
             GitDiff.base_file(@base, path, cmd: failed)
  end

  @tag spec: "mutagen.git_diff.r6"
  test "rejects invalid base SHA and out-of-scope paths before Git runs" do
    opts = [cmd: &unexpected_command/3]

    assert {:error, :diff_unavailable, %{cause: :invalid_base_sha}} =
             GitDiff.base_file("--help", "lib/a.ex", opts)

    for path <- ["/lib/a.ex", "other/a.ex", "lib/../a.ex", "lib/a\0.ex"] do
      assert {:error, :diff_unavailable, %{cause: :invalid_path}} =
               GitDiff.base_file(@base, path, opts)
    end
  end

  defp changed(output), do: GitDiff.changed_lines(@ref, cmd: runner(%{diff: {output, 0}}))

  defp runner(overrides, inspect_call \\ fn _args, _opts -> :ok end) do
    defaults = %{
      repository: {"false\n", 0},
      config: {"", 1},
      resolve_ref: {@since <> "\n", 0},
      resolve_head: {@head <> "\n", 0},
      merge_base: {@base <> "\n", 0},
      diff: {"", 0}
    }

    responses = Map.merge(defaults, overrides)

    fn "git", argv, opts ->
      args = git_args(argv)
      inspect_call.(args, opts)
      Map.fetch!(responses, step_for(args))
    end
  end

  defp git_args(["--no-pager" | args]), do: strip_config(args)

  defp strip_config(["-c", _setting | rest]), do: strip_config(rest)
  defp strip_config(args), do: args

  defp step_for(["rev-parse", "--is-shallow-repository"]), do: :repository
  defp step_for(["config" | _]), do: :config

  defp step_for(["rev-parse", "--verify", "--quiet", "--end-of-options", "HEAD^{commit}"]),
    do: :resolve_head

  defp step_for([
         "rev-parse",
         "--verify",
         "--quiet",
         "--end-of-options",
         "refs/heads/main^{commit}"
       ]),
       do: :resolve_ref

  defp step_for(["merge-base", @since, @head]), do: :merge_base
  defp step_for(["diff" | _]), do: :diff
  defp step_for(["ls-tree" | _]), do: :base_tree
  defp step_for(["show" | _]), do: :base_file

  defp steps_through(step) do
    {before_step, [^step | _]} =
      Enum.split_while(
        [:repository, :config, :resolve_ref, :resolve_head, :merge_base, :diff],
        &(&1 != step)
      )

    [step | before_step]
  end

  defp unexpected_command(_executable, args, _opts),
    do: flunk("unexpected Git call #{inspect(args)}")

  defp diff(records) do
    raw =
      Enum.map(records, fn {status, paths, mode, _body} ->
        [":100644 ", mode, " 0000000 abcdef0 ", status, 0, Enum.map(paths, &[&1, 0])]
      end)

    patch =
      Enum.map(records, fn {_status, _paths, _mode, body} ->
        ["diff --git a/unused b/unused\n", body]
      end)

    stats =
      Enum.map(records, fn
        {_status, [path], _mode, _body} -> ["0\t0\t", path, 0]
        {_status, [old, new], _mode, _body} -> ["0\t0\t", 0, old, 0, new, 0]
      end)

    IO.iodata_to_binary([raw, stats, 0, patch])
  end
end
