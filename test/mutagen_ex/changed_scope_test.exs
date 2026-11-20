defmodule MutagenEx.ChangedScopeTest do
  use ExUnit.Case, async: false

  alias MutagenEx.{ChangedRun, ChangedScope, Config}
  alias MutagenEx.JsonReporter.Report

  defmodule ControlledGit do
    def changed_lines(ref, opts), do: Process.get(:diff).(ref, opts)
    def base_file(base, path, opts), do: Process.get(:base).(base, path, opts)
  end

  @tag :tmp_dir
  @tag spec: "mutagen.cli.r34"
  test "the changed-code orchestrator refuses an umbrella before reading a diff", %{tmp_dir: dir} do
    File.write!(Path.join(dir, "mix.exs"), """
    defmodule ChangedRunUmbrellaFixture do
      use Mix.Project
      def project, do: [apps_path: "apps"]
    end
    """)

    config = %Config{since: "HEAD", scopes: [], tests: ["auto"]}
    report = %Report{}

    Mix.Project.in_project(:changed_run_umbrella_fixture, dir, fn _ ->
      assert {:abort, ^report, ^config, :umbrella_root, _} =
               ChangedRun.run(config, report, %{command: nil})
    end)
  end

  @tag :tmp_dir
  @tag spec: ["mutagen.scope_resolution.r12", "mutagen.json_schema.r31"]
  test "a failed base read stays incomplete and counts only actually touched entries", %{
    tmp_dir: dir
  } do
    File.cd!(dir, fn ->
      File.mkdir_p!("src")

      File.write!("src/sample.ex", """
      defmodule Sample do
        def earlier(x), do: x + 1

        def changed(x), do: x - 2
      end
      """)

      Process.put(:diff, fn _, _ ->
        {:ok,
         %{
           files: %{"src/sample.ex" => [{4, 4}]},
           deletion_anchors: %{},
           renames: %{},
           skipped: [],
           base: "base",
           head: "head",
           warnings: []
         }}
      end)

      Process.put(:base, fn _, _, _ -> {:error, :diff_unavailable, %{cause: :io}} end)

      config = %Config{since: "HEAD", scopes: [], tests: ["auto"], source: false}
      assert {:ok, plan} = ChangedScope.plan(config, ["src"], git: ControlledGit)
      assert plan.incomplete == [%{reason: :base_read_failed, path: "src/sample.ex"}]
      assert plan.meta.planned == 1
      assert [%{function: "Sample.changed/1"}] = plan.sites
    end)
  end

  @tag spec: "mutagen.scope_resolution.r12"
  test "test selection refuses a base or HEAD change between the two Git reads" do
    plan = %{meta: %{ref: "main", base: "base"}, head: "head"}

    for {base, head} <- [{"different", "head"}, {"base", "different"}] do
      Process.put(:diff, fn "main", _ ->
        {:ok, %{base: base, head: head, files: %{}, skipped: []}}
      end)

      assert {:error, :diff_unavailable, %{cause: :history_changed}} =
               ChangedScope.changed_tests(plan, ["checks"], ControlledGit)
    end
  end
end
