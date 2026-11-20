defmodule MutagenEx.GateWiringTest do
  use ExUnit.Case, async: false

  alias MutagenEx.{ChangedScope, CLI}

  @moduletag :git_diff_integration
  @moduletag timeout: to_timeout(minute: 2)

  @source "src/gate_fixture/example.ex"
  @convention "checks/gate_fixture/example_test.exs"

  setup do
    suffix = Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    repo = Path.join(File.cwd!(), "tmp/gate_fixture_#{suffix}")
    File.mkdir_p!(repo)
    on_exit(fn -> File.rm_rf!(repo) end)

    write(repo, "mix.exs", """
    defmodule GateFixture.MixProject do
      use Mix.Project

      def project do
        [
          app: :gate_fixture,
          version: "0.0.0",
          elixirc_paths: ["src"],
          test_paths: ["checks"],
          deps: [{:mutagen_ex, path: #{inspect(File.cwd!())}}],
          aliases: [test: [fn _ -> File.write!("booted", "yes") end, "test"]]
        ]
      end
    end
    """)

    write(repo, "checks/test_helper.exs", """
    ExUnit.start()
    :persistent_term.put(:gate_fixture_server, Process.whereis(ExUnit.Server))
    """)

    write(repo, ".gitignore", "/_build/\n/deps/\n")
    git(repo, ~w(init -b main))
    git(repo, ["config", "user.email", "fixture@example.invalid"])
    git(repo, ["config", "user.name", "Fixture"])
    {:ok, repo: repo}
  end

  @tag spec: [
         "mutagen.scope_resolution.r11",
         "mutagen.mutation_pipeline.r28",
         "mutagen.json_schema.r28"
       ]
  test "plans semantic changes and records uncovered sites, with a scope intersection", %{
    repo: repo
  } do
    write(repo, @source, source(1))
    narrow_tests(repo)
    base = commit(repo)
    write(repo, @source, source(2))

    report = run(repo, ["--since", "HEAD", "--no-escalate"])
    assert %{"ref" => "HEAD", "base" => ^base, "changed_files" => 1} = report["meta"]["since"]
    assert report["meta"]["since"]["planned"] == report["meta"]["since"]["in_scope"]
    assert report["meta"]["since"]["runtime"] > report["meta"]["since"]["run"]
    assert report["meta"]["complete"]
    assert report["meta"]["incomplete_reasons"] == []
    assert report["meta"]["fail_fast"]
    assert File.read!(Path.join(repo, "booted")) == "yes"

    assert [_ | _] = report["mutation"]["results"]
    assert [_ | _] = report["mutation"]["pending"]

    for row <- report["mutation"]["results"] ++ report["mutation"]["pending"] do
      refute Map.has_key?(row, "fingerprint")
      assert row["in_scope"] == "changed_group"
      refute row["function"] =~ "unchanged"
    end

    assert Enum.all?(report["mutation"]["pending"], &(&1["reason"] == "uncovered"))

    args = ["--since", base, "--scope", "GateFixture.Example.function_pick/1", "--no-escalate"]
    scoped = run(repo, args)
    assert scoped["mutation"]["pending"] == []
    assert [_ | _] = scoped["mutation"]["results"]

    assert Enum.all?(
             scoped["mutation"]["results"],
             &(&1["function"] == "GateFixture.Example.function_pick/1")
           )

    {:ok, config} = CLI.parse(args)

    assert {:ok, %{sites: [_ | _]}} =
             File.cd!(repo, fn -> ChangedScope.plan(config, ["src"]) end)
  end

  @tag spec: ["mutagen.scope_resolution.r11", "mutagen.mutation_pipeline.r28"]
  test "empty, formatting, comment, moved function and rename changes skip host boot", %{
    repo: repo
  } do
    original = """
    defmodule GateFixture.Example do
      def first(x), do: x + 1
      def second(x), do: x + 2
    end
    """

    write(repo, @source, original)
    base = commit(repo)

    assert_fast(run(repo, ["--since", base]), repo)
    assert_fast(run(repo, ["--since", base, "--tests", "checks/missing_test.exs"]), repo)

    for changed <- [
          String.replace(original, "x + 1", "x+1"),
          String.replace(original, "x + 1", "x + 1 # comment"),
          String.replace(original, ~r/(  def first[^\n]+\n)(  def second[^\n]+\n)/, "\\2\\1"),
          original
          |> String.replace("  def first(x), do: x + 1", "  def first(x) do\n    x + 1\n  end")
        ] do
      write(repo, @source, changed)
      assert_fast(run(repo, ["--since", base]), repo)
    end

    write(repo, @source, original)
    git(repo, ["mv", @source, "src/gate_fixture/renamed.ex"])
    renamed = run(repo, ["--since", base])
    assert renamed["warnings"] == ["no_runtime_sites"]
    assert_fast(renamed, repo)
  end

  @tag spec: ["mutagen.scope_resolution.r11", "mutagen.coverage.r12"]
  test "plans a deletion-only file even with no selected tests", %{repo: repo} do
    original = """
    defmodule GateFixture.Example do
      def first(x) do
        _ignored = x > 0
        x + 1
      end
    end
    """

    write(repo, @source, original)
    base = commit(repo)
    write(repo, @source, String.replace(original, "    _ignored = x > 0\n", ""))

    report = run(repo, ["--since", base, "--no-escalate"])
    assert report["meta"]["since"]["changed_files"] == 1

    assert [%{"function" => "GateFixture.Example.first/1", "reason" => "uncovered"} | _] =
             report["mutation"]["pending"]

    assert_fast(report, repo)
  end

  @tag spec: ["mutagen.scope_resolution.r11", "mutagen.coverage.r12", "mutagen.json_schema.r28"]
  test "uses rename base, deletion anchors and skipped links", %{repo: repo} do
    original = """
    defmodule GateFixture.Example do
      def first(x) do
        _ignored = x > 0
        x + 1
      end

      def second(x), do: x + 2

      def elsewhere(x), do: x + 3
    end
    """

    write(repo, @source, original)
    base = commit(repo)
    renamed = "src/gate_fixture/renamed.ex"
    git(repo, ["mv", @source, renamed])

    changed =
      original
      |> String.replace("    _ignored = x > 0\n", "")
      |> String.replace("do: x + 2", "do: x+2")

    write(repo, renamed, changed)

    link = "src/gate_fixture/link.ex"
    File.ln_s!("renamed.ex", Path.join(repo, link))
    git(repo, ["add", link])

    report = run(repo, ["--since", base, "--no-escalate"])
    assert report["meta"]["since"]["changed_files"] == 1
    assert %{"path" => link, "reason" => "symlink"} in report["meta"]["incomplete_reasons"]
    assert report["mutation"]["results"] == []

    assert [%{"file" => ^renamed, "function" => "GateFixture.Example.first/1"} | _] =
             report["mutation"]["pending"]

    assert Enum.all?(report["mutation"]["pending"], &(&1["function"] =~ ".first/1"))
    refute File.exists?(Path.join(repo, "booted"))
  end

  @tag spec: [
         "mutagen.test_selection.r9",
         "mutagen.test_selection.r10",
         "mutagen.coverage.r12",
         "mutagen.mutation_pipeline.r29",
         "mutagen.json_schema.r29"
       ]
  test "escalates only survivors and newly covered sites using green files and caps matches", %{
    repo: repo
  } do
    write(repo, @source, source(1))
    narrow_tests(repo)
    escalation_tests(repo)
    base = commit(repo)
    write(repo, @source, source(2))

    changed_test = "checks/changed_test.exs"
    write(repo, changed_test, test_case("Changed", ~s|test "runs", do: assert(true)|))

    args = ["--since", base, "--include-host-output"]
    report = run(repo, args)

    assert %{"path" => changed_test, "why" => "changed_in_diff"} in report["meta"][
             "tests_selected"
           ]

    assert %{"path" => @convention, "why" => "convention"} in report["meta"]["tests_selected"]

    assert result_selection(report, "module_pick") == %{
             "killed_at" => "module",
             "steps_run" => ["narrow", "module"]
           }

    assert result_selection(report, "function_pick") == %{
             "killed_at" => "function",
             "steps_run" => ["narrow", "module", "function"]
           }

    assert result_selection(report, "always_survives") == %{
             "killed_at" => nil,
             "steps_run" => ["narrow", "module", "function"]
           }

    assert result_selection(report, "newly_covered") == %{
             "killed_at" => "module",
             "steps_run" => ["module"]
           }

    assert [%{"step" => "module"} = module_step, %{"step" => "function"} = function_step] =
             report["meta"]["escalation"]

    assert report["baseline"]["passed"] == 2
    assert module_step["baseline"]["passed"] == 1
    assert module_step["files_added"] == ["checks/module_test.exs"]
    assert function_step["files_added"] == ["checks/function_test.exs"]
    assert module_step["survivors_out"] < module_step["survivors_in"]
    assert function_step["survivors_out"] < function_step["survivors_in"]
    refute module_step["capped"]

    assert Enum.any?(
             report["warnings"],
             &String.contains?(&1, "escalation_baseline_red: checks/red_test.exs")
           )

    assert Enum.any?(
             report["warnings"],
             &String.contains?(&1, "escalation_test_file_load_failed: checks/broken_test.exs")
           )

    assert File.read!(Path.join(repo, "narrow-runs")) == String.duplicate("run\n", 5)
    assert File.read!(Path.join(repo, "module-loads")) == "once\n"
    assert File.read!(Path.join(repo, "function-loads")) == "once\n"

    capped = run(repo, args ++ ["--escalate-max-files", "1"])

    assert [%{"capped" => true, "files_added" => ["checks/module_test.exs"]} | _] =
             capped["meta"]["escalation"]

    assert clean_timings(raw_run(repo, ["--since", base])) ==
             clean_timings(raw_run(repo, ["--since", base]))
  end

  @tag spec: "mutagen.json_schema.r28"
  test "uses fixed diff abort details and marks parse failures incomplete", %{repo: repo} do
    write(repo, @source, "defmodule Broken do\n")
    base = commit(repo)
    write(repo, @source, source(1))

    report = run(repo, ["--since", base, "--no-escalate"])

    assert %{"path" => @source, "reason" => "base_parse_error"} in report["meta"][
             "incomplete_reasons"
           ]

    write(repo, @source, "defmodule AlsoBroken do\n")
    report = run(repo, ["--since", base])

    assert %{"path" => @source, "reason" => "current_parse_error"} in report["meta"][
             "incomplete_reasons"
           ]

    assert_fast(report, repo, incomplete: true)

    {raw, 2} = invoke(repo, ["--since", "HEAD;redact-fixture"])
    refute raw =~ "redact-fixture"

    assert %{"abort_reason" => "invalid_since_ref", "details" => %{"cause" => "invalid_ref"}} =
             JSON.decode!(raw)

    {raw, 2} = invoke(repo, ["--since", "missing-ref"])

    assert %{"abort_reason" => "diff_unavailable", "details" => %{"cause" => "unresolvable_ref"}} =
             JSON.decode!(raw)

    refute raw =~ "missing-ref"
  end

  @tag spec: ["mutagen.cli.r34", "mutagen.scope_resolution.r12"]
  test "preflights umbrella, missing paths, and self mutation", %{repo: repo} do
    base = commit(repo)
    {missing, 2} = invoke(repo, ["--since", base])

    assert %{
             "abort_reason" => "diff_unavailable",
             "details" => %{"cause" => "invalid_root_directory"}
           } =
             JSON.decode!(missing)

    refute File.exists?(Path.join(repo, "booted"))

    write(
      repo,
      @source,
      "defmodule MutagenEx.LocalExample do\n  def changed(x), do: x + 1\nend\n"
    )

    {self, 2} = invoke(repo, ["--since", base])

    assert %{"abort_reason" => "self_mutation_refused", "coverage" => nil, "baseline" => nil} =
             JSON.decode!(self)

    refute File.exists?(Path.join(repo, "booted"))

    write(repo, "mix.exs", """
    defmodule GateUmbrella.MixProject do
      use Mix.Project
      def project, do: [apps_path: "apps"]
    end
    """)

    File.mkdir_p!(Path.join(repo, "apps"))
    {umbrella, 2} = invoke(repo, ["--since", base])
    assert %{"abort_reason" => "umbrella_root"} = JSON.decode!(umbrella)
  end

  @tag spec: ["mutagen.scope_resolution.r12", "mutagen.json_schema.r31"]
  test "reports changed non-runtime lines and ignores test support", %{repo: repo} do
    original = """
    defmodule GateFixture.Example do
      @limit 2
      defmacro add(x), do: quote(do: unquote(x) + 1)
      def keep(x), do: x + @limit
    end
    """

    write(repo, @source, original)

    write(
      repo,
      "test/support/factory.ex",
      "defmodule Factory do\n  def change(x), do: x + 1\nend\n"
    )

    project = File.read!(Path.join(repo, "mix.exs"))

    write(
      repo,
      "mix.exs",
      String.replace(
        project,
        ~s(elixirc_paths: ["src"]),
        ~s(elixirc_paths: ["src", "test/support"])
      )
    )

    base = commit(repo)

    write(
      repo,
      @source,
      original |> String.replace("@limit 2", "@limit 3") |> String.replace("+ 1", "+ 0")
    )

    write(
      repo,
      "test/support/factory.ex",
      "defmodule Factory do\n  def change(x), do: x - 1\nend\n"
    )

    report = run(repo, ["--since", base])

    assert report["meta"]["complete"]
    assert report["meta"]["since"]["runtime"] == 0
    assert report["meta"]["since"]["changed_files"] == 1
    ranges = Enum.flat_map(report["meta"]["since"]["unmapped"], & &1["ranges"])
    assert Enum.sort(Enum.flat_map(ranges, fn [f, l] -> Enum.to_list(f..l) end)) == [2, 3]

    assert Enum.all?(
             report["meta"]["since"]["unmapped"],
             &(&1["path"] == @source and &1["kind"] == "no_runtime_site")
           )

    assert_fast(report, repo)

    write(repo, @source, "")
    deleted = run(repo, ["--since", base])

    assert [%{"kind" => "deletion_without_neighbor", "path" => @source, "ranges" => [[0, 0]]}] =
             deleted["meta"]["since"]["unmapped"]

    assert_fast(deleted, repo)
  end

  @tag spec: ["mutagen.mutation_pipeline.r31", "mutagen.coverage.r13", "mutagen.json_schema.r31"]
  test "discovers tests without a convention and drops a hanging candidate", %{repo: repo} do
    write(repo, @source, "defmodule GateFixture.Example do\n  def value(x), do: x + 1\nend\n")

    write(
      repo,
      "checks/a_hang_test.exs",
      test_case("Hang", """
      # GateFixture.Example GateFixture.Example
      test "waits forever", do: Process.sleep(:infinity)
      """)
    )

    write(repo, "checks/a_crash_test.exs", "# GateFixture.Example\nexit(:candidate_crash)\n")

    write(
      repo,
      "checks/b_green_test.exs",
      test_case("Green", """
      test "checks the value", do: assert(GateFixture.Example.value(2) == 4)
      """)
    )

    write(
      repo,
      "checks/c_victim_test.exs",
      test_case("Victim", """
      # GateFixture.Example
      test "finds a clean host", do: assert(is_nil(Application.get_env(:gate_fixture, :polluted)))
      """)
    )

    write(
      repo,
      "checks/d_polluter_test.exs",
      "Application.put_env(:gate_fixture, :polluted, true)\n" <>
        test_case("Polluter", """
        # GateFixture.Example
        test "passes alone", do: assert(true)
        """)
    )

    base = commit(repo)
    write(repo, @source, "defmodule GateFixture.Example do\n  def value(x), do: x + 2\nend\n")
    report = run(repo, ["--since", base, "--timeout-ms", "1000"])
    assert report["baseline"]["passed"] == 0

    assert [
             %{
               "status" => "killed",
               "selection" => %{"killed_at" => "module", "steps_run" => ["module"]}
             }
           ] =
             report["mutation"]["results"]

    assert [
             %{
               "files_added" => ["checks/b_green_test.exs", "checks/c_victim_test.exs"],
               "baseline" => %{"passed" => 2}
             }
           ] =
             report["meta"]["escalation"]

    assert ["checks/b_green_test.exs", "checks/c_victim_test.exs"] ==
             Enum.map(report["meta"]["tests_selected"], & &1["path"])

    assert Enum.any?(
             report["warnings"],
             &String.starts_with?(&1, "escalation_baseline_red_in_combination:")
           )

    assert Enum.any?(report["warnings"], &String.starts_with?(&1, "escalation_baseline_timeout:"))
    assert Enum.any?(report["warnings"], &String.starts_with?(&1, "escalation_baseline_crashed:"))
  end

  defp source(n) do
    """
    defmodule GateFixture.Example do
      def module_pick(x), do: x + #{n}
      def function_pick(x), do: x + #{n}
      def always_survives(x), do: x + #{n}
      def newly_covered(x), do: x + #{n}
      def never_called(x), do: x + #{n}
      def unchanged(x), do: x + 1
    end
    """
  end

  defp narrow_tests(repo) do
    write(
      repo,
      @convention,
      test_case("Narrow", """
      alias GateFixture.Example

      test "reaches three changed lines" do
        File.write!("narrow-runs", "run\\n", [:append])
        assert is_integer(Example.module_pick(2))
        assert is_integer(Example.function_pick(2))
        assert is_integer(Example.always_survives(2))
      end
      """)
    )
  end

  defp escalation_tests(repo) do
    write(
      repo,
      "checks/module_test.exs",
      """
      File.write!("module-loads", "once\n", [:append])
      """ <>
        test_case("Module", """
        # GateFixture.Example GateFixture.Example GateFixture.Example
        alias GateFixture.Example

        test "kills one survivor and covers a new line" do
          assert Example.module_pick(2) == 4
          assert Example.newly_covered(2) == 4
        end
        """)
    )

    write(
      repo,
      "checks/function_test.exs",
      """
      File.write!("function-loads", "once\n", [:append])
      """ <>
        test_case("Function", """
        test "kills a second survivor" do
          module = Module.concat(GateFixture, Example)
          assert module.function_pick(2) == 4
        end
        """)
    )

    write(
      repo,
      "checks/red_test.exs",
      test_case("Red", """
      # GateFixture.Example
      test "fails on the original code", do: flunk("fixture")
      """)
    )

    write(
      repo,
      "checks/broken_test.exs",
      "# GateFixture.Example\nraise \"fixture load failure\"\n"
    )
  end

  defp test_case(name, body) do
    """
    defmodule GateFixture.#{name}Test do
      use ExUnit.Case

      setup_all do
        assert Process.whereis(ExUnit.Server) == :persistent_term.get(:gate_fixture_server)
        :ok
      end

    #{body}
    end
    """
  end

  defp result_selection(report, name) do
    report["mutation"]["results"]
    |> Enum.find(
      &(&1["function"] == "GateFixture.Example.#{name}/1" and &1["mutator"] == "arith")
    )
    |> Map.fetch!("selection")
  end

  defp assert_fast(report, repo, opts \\ []) do
    assert report["mutation"]["results"] == []
    assert report["baseline"]["passed"] == 0
    assert report["coverage"]["covered_lines"] == %{}
    assert report["meta"]["incomplete_reasons"] != [] == Keyword.get(opts, :incomplete, false)
    refute File.exists?(Path.join(repo, "booted"))
  end

  defp clean_timings(raw) do
    raw
    |> String.replace(~r/"timings_ms":\{[^{}]+\},|,"timings_ms":\{[^{}]+\}(?=\})/, "")
    |> String.replace(~r/"(wall_ms|baseline_ms|mutant_deadline_ms)":\d+/, ~s("\\1":0))
  end

  defp run(repo, args), do: repo |> raw_run(args) |> JSON.decode!()

  defp raw_run(repo, args) do
    {body, status} = invoke(repo, args)
    assert status == 0, body
    assert body |> String.split("\n", trim: true) |> length() == 1
    body
  end

  defp invoke(repo, args) do
    ebin = Path.expand(Mix.Project.compile_path())

    System.cmd("elixir", ["-pa", ebin, "-S", "mix", "mutagen" | args],
      cd: repo,
      env: [
        {"MIX_ENV", "test"},
        {"ERL_AFLAGS", "+S 2:2 +SDcpu 1 +SDio 2"}
      ]
    )
  end

  defp write(repo, file, text) do
    target = Path.join(repo, file)
    File.mkdir_p!(Path.dirname(target))
    File.write!(target, text)
  end

  defp commit(repo) do
    git(repo, ~w(add --all))
    git(repo, ~w(commit -m Base))
    repo |> git(~w(rev-parse HEAD)) |> String.trim()
  end

  defp git(repo, args) do
    {out, code} = System.cmd("git", args, cd: repo, stderr_to_stdout: true)
    assert code == 0, out
    out
  end
end
