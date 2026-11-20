defmodule MutagenEx.GateWiringTest do
  use ExUnit.Case, async: false

  alias MutagenEx.{ChangedScope, CLI, GitDiff}

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
         "mutagen.json_schema.r28",
         "mutagen.cli.r36",
         "mutagen.json_schema.r37"
       ]
  test "plans semantic changes and records uncovered sites, with a scope intersection", %{
    repo: repo
  } do
    write(repo, @source, source(1))
    narrow_tests(repo)
    base = commit(repo)
    write(repo, @source, source(2))

    report = run(repo, ["--since", "HEAD", "--no-escalate", "--summary", "out/narrow.md"])
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

    assert_summary(
      report,
      ["newly_covered", "never_called"],
      [
        {"module_pick", "arith"},
        {"function_pick", "arith"},
        {"always_survives", "arith"}
      ]
    )

    assert_markdown(repo, "out/narrow.md", "summary_git_narrow", base)
    assert_reruns(repo, report)

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
         "mutagen.json_schema.r29",
         "mutagen.json_schema.r36",
         "mutagen.json_schema.r37"
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

    args = ["--since", base]
    report = run(repo, args ++ ["--summary", "out/escalated.md"])

    assert %{"path" => changed_test, "why" => "changed_in_diff"} in report["meta"][
             "tests_selected"
           ]

    assert %{"path" => @convention, "why" => "convention"} in report["meta"]["tests_selected"]

    assert result_selection(report, "module_pick") == %{
             "killed_at" => "module",
             "after_dropped_file" => true,
             "steps_run" => ["narrow", "module"]
           }

    assert result_selection(report, "function_pick") == %{
             "killed_at" => "function",
             "after_dropped_file" => true,
             "steps_run" => ["narrow", "module", "function"]
           }

    assert result_selection(report, "always_survives") == %{
             "killed_at" => nil,
             "after_dropped_file" => true,
             "steps_run" => ["narrow", "module", "function"]
           }

    assert result_selection(report, "newly_covered") == %{
             "killed_at" => "module",
             "after_dropped_file" => true,
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
    assert module_step["dropped_after_load"] == 2
    assert function_step["dropped_after_load"] == 0

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

    assert_summary(report, ["never_called"], [{"always_survives", "arith"}])

    notes = report["summary"]["notes"]
    assert %{"kind" => "kills_after_dropped_file", "count" => 3} in notes
    assert %{"kind" => "escalation_dropped_after_load", "count" => 2} in notes

    assert %{
             "kind" => "escalation_dropped",
             "count" => 1,
             "reason" => "escalation_baseline_red",
             "files" => ["checks/red_test.exs"]
           } in notes

    assert %{
             "kind" => "escalation_dropped",
             "count" => 1,
             "reason" => "escalation_test_file_load_failed",
             "files" => ["checks/broken_test.exs"]
           } in notes

    assert_markdown(repo, "out/escalated.md", "summary_git_escalated", base)
    assert_reruns(repo, report)

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

    assert %{
             "abort_reason" => "self_mutation_refused",
             "coverage" => nil,
             "baseline" => nil,
             "details" => %{
               "hint" =>
                 "For changes to Mutagen itself, run mix test and mix test.integration." <> _
             }
           } = JSON.decode!(self)

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

  @tag spec: [
         "mutagen.scope_resolution.r12",
         "mutagen.scope_resolution.r13",
         "mutagen.json_schema.r31"
       ]
  test "reports only changed non-runtime code and ignores test support", %{repo: repo} do
    original = """
    defmodule GateFixture.Example do
      @limit 2
      defmacro add(x), do: quote(do: unquote(x) + 1)
      defguard inside(x) when is_integer(x)
      defstruct [
        :name
      ]
      defdelegate parse(x), to: Integer
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
      original
      |> String.replace("Example do", "Example do # module")
      |> String.replace("@limit 2", "@limit 3")
      |> String.replace("+ 1", "+ 0")
      |> String.replace("is_integer", "is_number")
      |> String.replace(":name", ":title")
      |> String.replace("defdelegate parse", "defdelegate other")
      |> String.replace("  def keep", "\n  # only a comment\n  def keep")
      |> String.replace("\nend\n", "\nend # closing\n")
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

    assert Enum.sort(Enum.flat_map(ranges, fn [f, l] -> Enum.to_list(f..l) end)) == [
             2,
             3,
             4,
             6,
             8
           ]

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

  @tag spec: ["mutagen.mutation_pipeline.r32", "mutagen.json_schema.r36"]
  test "a countdown timeout stays in the narrow pass", %{repo: repo} do
    original = """
    defmodule GateFixture.Example do
      def countdown(n), do: if(n == 0, do: :done, else: countdown(n - 2))
    end
    """

    write(repo, @source, original)

    write(
      repo,
      @convention,
      test_case("Countdown", """
      test "counts down", do: assert(GateFixture.Example.countdown(3) == :done)
      """)
    )

    zero_test = "checks/zero_test.exs"

    write(
      repo,
      zero_test,
      test_case("Zero", """
      test "base case", do: assert(GateFixture.Example.countdown(0) == :done)
      """)
    )

    base = commit(repo)
    write(repo, @source, String.replace(original, "n - 2", "n - 1"))
    args = ["--since", base, "--timeout-ms", "1000"]
    auto = run(repo, args)
    assert %{"files_added" => [^zero_test]} = hd(auto["meta"]["escalation"])

    explicit = run(repo, args ++ ["--tests", @convention, "--tests", zero_test, "--no-escalate"])
    assert statuses(auto) == statuses(explicit)

    timeouts = Enum.filter(auto["mutation"]["results"], &(&1["before_source"] in ["n - 1", "1"]))
    assert [_ | _] = timeouts

    for row <- timeouts do
      assert row["status"] == "timeout"
      assert row["selection"]["steps_run"] == ["narrow"]
    end

    summary = auto["summary"]
    assert summary["unevaluated"]["timeout"] == length(timeouts)
    assert summary["counts"]["killed"] == auto["mutation"]["killed"]
    assert summary["counts"]["survived"] == auto["mutation"]["survived"]
  end

  @tag spec: ["mutagen.mutation_pipeline.r33", "mutagen.json_schema.r34"]
  test "restores rejected candidate environments and marks verdicts after the drop", %{repo: repo} do
    original = """
    defmodule GateFixture.Example do
      def early(x), do: x + 2
      def limit?(x), do: x > 11

      def strict_inc(x) do
        if :persistent_term.get(:gate_fixture_strict, false), do: x + 2, else: 2
      end
    end
    """

    write(repo, @source, original)

    write(repo, "checks/test_helper.exs", """
    ExUnit.start()
    :persistent_term.put(:gate_fixture_server, Process.whereis(ExUnit.Server))
    System.put_env("MUTAGEN_FIXTURE_ORIGINAL", "original")
    :ok = Application.ensure_loaded(:logger)
    Application.put_env(:logger, :mutagen_fixture_original, :original)
    """)

    write(
      repo,
      @convention,
      test_case("NarrowLeak", """
      alias GateFixture.Example
      test "weak for the escalated functions" do
        assert Example.early(1) == 2
        assert is_boolean(Example.limit?(3))
        assert is_integer(Example.strict_inc(1))
      end
      """)
    )

    dropper = "checks/dropper_test.exs"

    write(
      repo,
      dropper,
      """
      :persistent_term.put(:gate_fixture_strict, true)
      System.put_env("MUTAGEN_FIXTURE_ADDED", "dropper")
      System.delete_env("MUTAGEN_FIXTURE_ORIGINAL")
      Application.put_env(:logger, :mutagen_fixture_added, :dropper)
      Application.delete_env(:logger, :mutagen_fixture_original)
      """ <>
        test_case("Dropper", """
        # GateFixture.Example GateFixture.Example
        test "is red on the original" do
          System.put_env("MUTAGEN_FIXTURE_BODY", "dropper")
          Application.put_env(:logger, :mutagen_fixture_body, :dropper)
          flunk("rejected candidate")
        end
        """)
    )

    keeper = "checks/keeper_test.exs"

    write(
      repo,
      keeper,
      test_case("Keeper", """
      test "sees the original environments but the persistent term remains" do
        assert System.get_env("MUTAGEN_FIXTURE_ORIGINAL") == "original"
        refute System.get_env("MUTAGEN_FIXTURE_ADDED")
        refute System.get_env("MUTAGEN_FIXTURE_BODY")
        assert Application.get_env(:logger, :mutagen_fixture_original) == :original
        refute Application.get_env(:logger, :mutagen_fixture_added)
        refute Application.get_env(:logger, :mutagen_fixture_body)
        assert :persistent_term.get(:gate_fixture_strict)
        assert GateFixture.Example.limit?(11)
        refute GateFixture.Example.limit?(10)
      end
      """)
    )

    function_test = "checks/strict_inc_test.exs"

    write(
      repo,
      function_test,
      test_case("FunctionLeak", """
      test "checks strict_inc" do
        mod = Module.concat(GateFixture, Example)
        assert mod.strict_inc(1) == 2
      end
      """)
    )

    base = commit(repo)

    write(
      repo,
      @source,
      original |> String.replace("x + 2", "x + 1") |> String.replace("> 11", "> 10")
    )

    report = run(repo, ["--since", base])

    assert [
             %{"step" => "module", "dropped_after_load" => 1, "files_added" => [^keeper]},
             %{"step" => "function", "dropped_after_load" => 0, "files_added" => [^function_test]}
           ] = report["meta"]["escalation"]

    assert "escalation_baseline_red: #{dropper}" in report["warnings"]
    refute result_selection(report, "early")["after_dropped_file"]
    assert result_selection(report, "strict_inc")["after_dropped_file"]
    assert result_selection(report, "strict_inc")["killed_at"] == "function"

    assert Enum.any?(report["mutation"]["results"], fn row ->
             row["function"] == "GateFixture.Example.limit?/1" and row["status"] == "killed" and
               row["selection"]["after_dropped_file"] == true
           end)
  end

  @tag spec: ["mutagen.mutation_pipeline.r34", "mutagen.json_schema.r33"]
  test "group leader death kills each affected mutant and makes a baseline red", %{repo: repo} do
    write(repo, @source, """
    defmodule GateFixture.Example do
      def value(x), do: x + 1
    end
    """)

    write(
      repo,
      @convention,
      test_case("MutantCrash", """
      test "kills its group leader when it detects a mutant" do
        if GateFixture.Example.value(2) != 3 do
          Process.exit(Process.group_leader(), :kill)
          Process.sleep(:infinity)
        end
      end
      """)
    )

    args = ["--scope", @source, "--tests", @convention]
    report = run(repo, args)

    assert %{"total" => 2, "killed" => 2, "timeout" => 0} = report["mutation"]
    assert Enum.all?(report["mutation"]["results"], &(&1["status"] == "killed"))

    write(
      repo,
      @convention,
      test_case("BaselineCrash", """
      test "kills its group leader outside coverage" do
        assert GateFixture.Example.value(2) == 3

        if Process.whereis(:cover_server) == nil do
          Process.exit(Process.group_leader(), :kill)
          Process.sleep(:infinity)
        end
      end
      """)
    )

    {raw, 2} = invoke(repo, args)

    assert %{
             "abort_reason" => "baseline_red",
             "aborted" => true,
             "baseline" => %{"failed" => 1},
             "meta" => %{"complete" => false}
           } = JSON.decode!(raw)
  end

  @tag spec: "mutagen.mutation_pipeline.r34"
  test "drops a candidate that kills its group leader and still runs green candidates", %{
    repo: repo
  } do
    write(repo, @source, "defmodule GateFixture.Example do\n  def value(x), do: x + 2\nend\n")
    crashed = "checks/crash_test.exs"

    write(
      repo,
      crashed,
      test_case("CandidateCrash", """
      # GateFixture.Example GateFixture.Example
      test "kills its group leader" do
        Process.exit(Process.group_leader(), :kill)
        Process.sleep(:infinity)
      end
      """)
    )

    green = "checks/green_test.exs"

    write(
      repo,
      green,
      test_case("GreenAfterCrash", """
      test "checks the value", do: assert(GateFixture.Example.value(2) == 3)
      """)
    )

    base = commit(repo)
    write(repo, @source, "defmodule GateFixture.Example do\n  def value(x), do: x + 1\nend\n")
    report = run(repo, ["--since", base, "--timeout-ms", "1000"])

    assert [%{"dropped_after_load" => 1, "files_added" => [^green]}] =
             report["meta"]["escalation"]

    assert "escalation_baseline_red: #{crashed}" in report["warnings"]
    assert report["mutation"]["killed"] == 2
  end

  @tag spec: ["mutagen.mutation_pipeline.r35", "mutagen.json_schema.r34"]
  test "admits a green six-second test that kills limit mutants", %{repo: repo} do
    original = """
    defmodule GateFixture.Example do
      def limit?(x), do: x > 11
    end
    """

    write(repo, @source, original)

    write(
      repo,
      @convention,
      test_case("WeakLimit", """
      test "checks the type", do: assert(is_boolean(GateFixture.Example.limit?(3)))
      """)
    )

    slow = "checks/slow_test.exs"

    write(
      repo,
      slow,
      test_case("SlowLimit", """
      test "checks the boundary" do
        Process.sleep(to_timeout(second: 6))
        assert GateFixture.Example.limit?(11)
        refute GateFixture.Example.limit?(10)
      end
      """)
    )

    base = commit(repo)
    write(repo, @source, String.replace(original, "> 11", "> 10"))
    report = run(repo, ["--since", base])

    assert [
             %{
               "candidate_deadline_ms" => 30_000,
               "files_added" => [^slow],
               "dropped_after_load" => 0
             }
           ] =
             report["meta"]["escalation"]

    assert result_selection_for(report, "limit?/1", "compare")["killed_at"] == "module"
  end

  @tag spec: ["mutagen.git_diff.r11", "mutagen.json_schema.r35"]
  test "counts only untracked files it reads and names the root when that cap is exceeded", %{
    repo: repo
  } do
    write(repo, @source, "defmodule GateFixture.Example do\nend\n")
    base = commit(repo)

    for root <- ["src", "checks"] do
      vendor = Path.join([repo, root, "vendor"])
      File.mkdir!(vendor)
      for n <- 1..2_001, do: File.write!(Path.join(vendor, "#{n}.js"), "irrelevant")
    end

    assert_fast(run(repo, ["--since", base]), repo)

    vendor = Path.join(repo, "checks/vendor")
    for n <- 1..2_001, do: File.write!(Path.join(vendor, "#{n}_test.exs"), "# a test")

    assert {:error, :diff_unavailable, %{cause: :file_limit, root: "checks"}} =
             GitDiff.changed_lines(base,
               cd: repo,
               roots: ["checks"],
               file_kind: :test,
               untracked: true
             )

    {raw, 2} = invoke(repo, ["--since", base])

    assert %{
             "abort_reason" => "diff_unavailable",
             "meta" => %{"complete" => false},
             "details" => %{"cause" => "file_limit", "root" => "checks", "hint" => hint}
           } = JSON.decode!(raw)

    assert hint =~ "Untracked files under checks exceeded"
    assert hint =~ "Ignore the directory"

    write(repo, ".gitignore", "/_build/\n/deps/\n/checks/vendor/\n")
    assert_fast(run(repo, ["--since", base]), repo)
  end

  defp statuses(report) do
    Map.new(report["mutation"]["results"], &{&1["id"], &1["status"]})
  end

  @tag spec: ["mutagen.cli.r6", "mutagen.cli.r35", "mutagen.cli.r36", "mutagen.json_schema.r37"]
  test "summary output, site selection and aborts preserve the JSON contract", %{repo: repo} do
    write(repo, @source, source(1))
    narrow_tests(repo)
    base = commit(repo)
    write(repo, @source, source(2))

    changed = ["--since", base, "--no-escalate"]
    classic = ["--scope", @source, "--tests", @convention]
    write(repo, "out/directory/keep", "sentinel")
    File.ln_s!("directory/keep", Path.join(repo, "out/same.md"))

    report =
      run(repo, classic ++ ["--no-source", "--summary", "out/classic.md", "--summary-max", "1"])

    [entry] = report["summary"]["worth_a_look"]
    assert entry["rerun"] =~ "--no-source"
    assert_reruns(repo, report)
    assert File.stat!(Path.join(repo, "out/classic.md")).mode |> Bitwise.band(0o777) == 0o600
    refute File.read!(Path.join(repo, "out/classic.md")) =~ @source

    bad = [
      {changed ++ ["--summary", "-"], "unsafe_summary_path"},
      {changed ++ ["--summary", ".." <> "/outside.md"], "unsafe_summary_path"},
      {changed ++ ["--summary-max", "-1"], "invalid_summary_max"},
      {changed ++ ["--summary", "out/same.md", "--json", "out/directory/keep"],
       "summary_path_conflict"},
      {changed ++ ["--summary", "out/directory"], "summary_write_failed"},
      {changed ++ ["--site", String.duplicate("a", 64)], "site_not_found"}
    ]

    for {args, reason} <- bad do
      {body, code} = invoke(repo, args)

      if reason == "summary_path_conflict" do
        assert body == ""

        assert %{"abort_reason" => ^reason} =
                 repo |> Path.join("out/directory/keep") |> File.read!() |> JSON.decode!()
      else
        assert %{"abort_reason" => ^reason, "aborted" => true} = JSON.decode!(body)
      end

      assert code == 2
    end

    assert [] == Path.wildcard(Path.join(repo, "out/**/.mutagen-*.tmp"), match_dot: true)
  end

  defp assert_summary(report, check_first, worth) do
    summary = report["summary"]
    assert summary["verdict"] == "check_first"

    assert Enum.map(summary["check_first"], &{&1["kind"], &1["function"]}) ==
             Enum.map(check_first, &{"not_executed", "GateFixture.Example.#{&1}/1"})

    assert Enum.map(summary["worth_a_look"], &{&1["function"], &1["mutator"]}) ==
             Enum.map(worth, fn {name, mutator} -> {"GateFixture.Example.#{name}/1", mutator} end)
  end

  defp assert_markdown(repo, path, golden, base) do
    actual = repo |> Path.join(path) |> File.read!() |> String.replace(base, "<BASE>")
    golden = Path.join([__DIR__, "../mutagen_ex/golden", "#{golden}.md"])
    if System.get_env("REGEN") == "1", do: File.write!(golden, actual)
    assert actual == File.read!(golden)
  end

  defp assert_reruns(repo, report) do
    summary = report["summary"]

    entries =
      Enum.map(summary["check_first"], &{&1["example"], "uncovered"}) ++
        Enum.map(summary["worth_a_look"], &{&1, "survived"})

    for {entry, status} <- entries do
      ebin = Path.expand(Mix.Project.compile_path())
      flags = "+S 2:2 +SDcpu 1 +SDio 2 -pa #{inspect(ebin)}"
      {raw, 0} = System.cmd("sh", ["-c", entry["rerun"]], cd: repo, env: [{"ERL_AFLAGS", flags}])
      mutation = JSON.decode!(raw)["mutation"]
      assert [site] = mutation["results"] ++ mutation["pending"]
      assert (site["status"] || site["reason"]) == status

      selected =
        if summary["source"],
          do: site["id"],
          else: MutagenEx.MutationEnumerator.Site.reference(site["id"])

      assert selected == entry["id"]
    end
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

  defp result_selection(report, name), do: result_selection_for(report, "#{name}/1", "arith")

  defp result_selection_for(report, mfa, mutator) do
    report["mutation"]["results"]
    |> Enum.find(&(&1["function"] == "GateFixture.Example.#{mfa}" and &1["mutator"] == mutator))
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
    |> String.replace(
      ~r/"(wall_ms|baseline_ms|mutant_deadline_ms|candidate_deadline_ms)":\d+/,
      ~s("\\1":0)
    )
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
