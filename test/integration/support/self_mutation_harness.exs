defmodule MutagenEx.Integration.SelfMutationHarness do
  @moduledoc """
  Reproducible self-mutation harness for `mutagen_ex` (mutagen-bqd.3).

  ## Why a shadow project

  `mutagen_ex` refuses to mutate its own runtime: the CLI rejects any scope
  whose target names a module starting with `MutagenEx.` or equal to
  `Mix.Tasks.Mutagen` (see `.spec/decisions/self_mutation_refused.md`).
  Mutating the tool in the same BEAM that is running it would corrupt the
  runner mid-flight. That guard is a hard wall for in-process self-mutation —
  so to get a mutation score on mutagen_ex's own logic we run the
  *external-process* pattern already used by
  `test/integration/downstream_adoption_test.exs`: a brand-new Mix project in
  `System.tmp_dir!()` that drives `mix mutagen` via `System.cmd/3`.

  The twist is that the downstream project's source IS mutagen_ex's own
  source, copied verbatim but with its module namespace mechanically
  rewritten from `MutagenEx` to the shadow root (`@shadow_root`). The rewrite
  is a single uniform token substitution applied to both `lib/` and the cited
  test files, so every contract the source relies on — including the
  self-mutation guard's own prefix string and the tests that assert against it
  — moves together and stays self-consistent. Under the shadow namespace the
  resolved scope module is e.g. `SelfMut.JsonReporter`, which the guard does
  not match, so the real `mix mutagen` (wired in as a `path:` dep) mutates it
  like any third-party module.

  The shadow project never declares its own `mix mutagen` task — the Mix task
  module (`lib/mix/tasks/`) is excluded from the copy. The real `mutagen_ex`
  path dep supplies it. The shadow app and the real app coexist in the same VM
  under distinct namespaces.

  ## Output

  `score/1` returns `%{targets: [...], aggregate: %{...}}`. Each per-target
  entry is `%{name, scope, tests, total, killed, survived, kill_rate,
  aborted}`. The numbers are reproducible: mutation IDs are content-addressed
  and execution is serial+seeded inside `mutagen_ex` (see `.spec/decisions/`),
  so a clean run on unchanged source yields a stable `total` and kill set.
  """

  @shadow_root "SelfMut"

  # High-value modules this dogfood targets, per the ticket. Each entry is
  # `{name, lib source, cited test file}` in the *original* tree. The harness
  # copies the whole `lib/` closure (these modules cross-reference nearly the
  # entire project via facades), then aims `mix mutagen --scope` at each target
  # file in turn, citing that target's own test file.
  #
  # `cli` is deliberately NOT a target. The ticket names `cli` among the
  # high-value modules, but its cited test file (`cli_test.exs`) is
  # structurally incompatible with the shadow-rewrite mechanism: roughly half
  # of it drives `Mix.Tasks.Mutagen.run/2` — the Mix task module, which the
  # shadow excludes from the copy so the *real* `mutagen_ex` path-dep supplies
  # the `mix mutagen` task. Two of those tests can never pass under the shadow:
  #
  #   * one asserts the dispatched pipeline receives a `%SelfMut.Config{}`, but
  #     the real `Mix.Tasks.Mutagen` builds a `%MutagenEx.Config{}`;
  #   * one asserts `--scope SelfMut.MutationRunner` is refused as
  #     `:self_mutation_refused`, but the real guard only refuses the literal
  #     `MutagenEx.` prefix (see `.spec/decisions/self_mutation_refused.md`),
  #     so the shadow namespace sails straight through.
  #
  # Both failures redden the baseline before any mutation runs, and neither
  # test exercises `SelfMut.Cli` (the module we'd be mutating) at all — they
  # test the excluded Mix task. Rather than surgically excise tests from a
  # copied file (fragile, and it would leave the `cli.ex` parse logic thinly
  # covered), we score the three high-value modules whose tests are
  # self-contained under the rewrite. The CLI's pure parse logic is still
  # covered indirectly: `scope_resolver` consumes the scopes `cli.ex` parses.
  @targets [
    %{
      name: "mutators",
      lib: "lib/mutagen_ex/mutators.ex",
      test: "test/mutagen_ex/mutators_test.exs"
    },
    %{
      name: "scope_resolver",
      lib: "lib/mutagen_ex/scope_resolver.ex",
      test: "test/mutagen_ex/scope_resolver_test.exs"
    },
    %{
      name: "json_reporter",
      lib: "lib/mutagen_ex/json_reporter.ex",
      test: "test/mutagen_ex/json_reporter_test.exs"
    }
  ]

  @doc "The shadow namespace root the harness rewrites `MutagenEx` to."
  def shadow_root, do: @shadow_root

  @doc "The list of `%{name, lib, test}` target descriptors this harness scores."
  def targets, do: @targets

  @doc """
  Build a shadow project rooted at `mutagen_ex`'s own source, run
  `mix mutagen` against each target, and return per-target + aggregate scores.

  Options:

    * `:project_root` — absolute path to the mutagen_ex checkout to dogfood
      (defaults to the repo root inferred from this file's location).
    * `:targets` — override the default target list (used by tests to score a
      cheap subset).
    * `:tmp_dir` — base dir for the shadow project (defaults to
      `System.tmp_dir!()`). The project lives in a uniquely-named subdir and is
      removed on success unless `:keep` is true.
    * `:keep` — leave the shadow project on disk for inspection.
  """
  def score(opts \\ []) do
    project_root = Keyword.get(opts, :project_root, default_project_root())
    targets = Keyword.get(opts, :targets, @targets)
    base = Keyword.get(opts, :tmp_dir, System.tmp_dir!())

    rand = :rand.uniform(1_000_000_000) |> Integer.to_string()
    app_name = "mutagen_ex_self_mutation_#{rand}"
    shadow_dir = Path.join(base, app_name)

    File.rm_rf!(shadow_dir)

    try do
      build_shadow_project!(project_root, shadow_dir, app_name, targets)

      per_target = Enum.map(targets, &run_target(&1, shadow_dir))

      %{targets: per_target, aggregate: aggregate(per_target)}
    after
      unless Keyword.get(opts, :keep, false), do: File.rm_rf!(shadow_dir)
    end
  end

  # --- shadow project construction -------------------------------------------

  defp build_shadow_project!(project_root, shadow_dir, app_name, targets) do
    File.mkdir_p!(Path.join(shadow_dir, "lib"))
    File.mkdir_p!(Path.join(shadow_dir, "test"))

    # 1. Copy the whole lib/ closure (everything except the Mix task, which the
    #    real path-dep supplies) under the shadow namespace.
    src_lib = Path.join(project_root, "lib")

    src_lib
    |> all_ex_files()
    |> Enum.reject(&String.starts_with?(&1, "mix/tasks/"))
    |> Enum.each(fn rel ->
      contents = File.read!(Path.join(src_lib, rel)) |> rewrite()
      dest = Path.join([shadow_dir, "lib", rewrite_path(rel)])
      File.mkdir_p!(Path.dirname(dest))
      File.write!(dest, contents)
    end)

    # 2. Copy each target's cited test file under the shadow namespace.
    Enum.each(targets, fn t ->
      contents = File.read!(Path.join(project_root, t.test)) |> rewrite()
      dest = Path.join(shadow_dir, shadow_test_path(t.test))
      File.mkdir_p!(Path.dirname(dest))
      File.write!(dest, contents)
    end)

    # 3. Minimal mix.exs: the shadow app depends on the real mutagen_ex for the
    #    `mix mutagen` task and on :telemetry (the shadow lib emits the same
    #    telemetry events). No test aliases — the harness drives `mix mutagen`
    #    directly via System.cmd.
    File.write!(Path.join(shadow_dir, "mix.exs"), mix_exs(app_name, project_root))

    # 4. A test_helper so the shadow project's own `mix test` (used by the
    #    mutation runner's preamble to load test modules) starts ExUnit.
    File.write!(Path.join(shadow_dir, "test/test_helper.exs"), "ExUnit.start()\n")

    File.write!(
      Path.join(shadow_dir, ".formatter.exs"),
      "[inputs: [\"{lib,test}/**/*.{ex,exs}\"]]\n"
    )

    # 5. Resolve deps + compile once so the mutation run starts from a built
    #    project (matches downstream_adoption_test's precondition).
    {out, code} =
      System.cmd("mix", ["deps.get"], cd: shadow_dir, stderr_to_stdout: true, env: clean_env())

    unless code == 0, do: raise("shadow `mix deps.get` failed (#{code}):\n#{out}")

    {cout, ccode} =
      System.cmd("mix", ["compile"], cd: shadow_dir, stderr_to_stdout: true, env: clean_env())

    unless ccode == 0, do: raise("shadow `mix compile` failed (#{ccode}):\n#{cout}")
  end

  # --- per-target mutation run -----------------------------------------------

  defp run_target(target, shadow_dir) do
    scope = "lib/" <> rewrite_path(Path.relative_to(target.lib, "lib"))
    tests = shadow_test_path(target.test)

    {out, code} =
      System.cmd("mix", ["mutagen", "--scope", scope, "--tests", tests],
        cd: shadow_dir,
        stderr_to_stdout: false,
        env: clean_env()
      )

    decoded = decode_report!(out, code, target)

    # OTP's `:json.decode/1` represents JSON `null` as the atom `:null`. An
    # aborted run carries `"mutation": null` and a non-null `abort_reason`;
    # normalize both so a `mutation` block that is absent OR null degrades to
    # an empty map rather than crashing the score rollup.
    mutation =
      case decoded["mutation"] do
        m when is_map(m) -> m
        _ -> %{}
      end

    %{
      name: target.name,
      scope: scope,
      tests: tests,
      total: mutation["total"] || 0,
      killed: mutation["killed"] || 0,
      survived: mutation["survived"] || 0,
      kill_rate: mutation["kill_rate"],
      aborted: decoded["aborted"] == true,
      abort_reason: nullable(decoded["abort_reason"])
    }
  end

  defp aggregate(per_target) do
    total = Enum.reduce(per_target, 0, &(&1.total + &2))
    killed = Enum.reduce(per_target, 0, &(&1.killed + &2))

    %{
      total: total,
      killed: killed,
      survived: Enum.reduce(per_target, 0, &(&1.survived + &2)),
      kill_rate: if(total > 0, do: killed / total, else: nil)
    }
  end

  # --- namespace rewrite -----------------------------------------------------

  # Uniform token substitution applied identically to lib and test source so
  # every contract the source relies on stays self-consistent:
  #
  #   * `MutagenEx`  (module namespace)  -> `SelfMut`
  #   * `mutagen_ex` (lowercase: the OTP app atom `:mutagen_ex`, the
  #     `lib/mutagen_ex/` path segment, AND string-literal source paths the
  #     provenance tests read from disk, e.g.
  #     `File.read!("lib/mutagen_ex/scope_resolver.ex")`) -> `self_mut`
  #
  # The lowercase pass must be global, not just the atom form: several cited
  # tests assert against their own source by reading `lib/mutagen_ex/*.ex`,
  # and the shadow tree lives under `lib/self_mut/`. Rewriting the bare token
  # everywhere keeps those reads pointed at the shadow file (which carries the
  # rewritten source), so the baseline test run stays green.
  @shadow_app Macro.underscore(@shadow_root)
  defp rewrite(contents) do
    contents
    |> String.replace("MutagenEx", @shadow_root)
    |> String.replace("mutagen_ex", @shadow_app)
  end

  # `mutagen_ex/...` -> `self_mut/...` (the directory mirrors the underscored
  # shadow app name; only the first `mutagen_ex` segment is rewritten).
  defp rewrite_path(rel) do
    String.replace(rel, "mutagen_ex", Macro.underscore(@shadow_root), global: false)
  end

  defp shadow_test_path(original_test) do
    rel = Path.relative_to(original_test, "test")
    Path.join("test", rewrite_path(rel))
  end

  # --- helpers ---------------------------------------------------------------

  defp all_ex_files(dir) do
    Path.wildcard(Path.join(dir, "**/*.ex"))
    |> Enum.map(&Path.relative_to(&1, dir))
  end

  defp mix_exs(app_name, project_root) do
    """
    defmodule #{Macro.camelize(app_name)}.MixProject do
      use Mix.Project

      def project do
        [
          app: :#{app_name},
          version: "0.0.0",
          elixir: "~> 1.19",
          deps: deps()
        ]
      end

      def application do
        [extra_applications: [:logger]]
      end

      defp deps do
        [
          {:telemetry, "~> 1.0"},
          {:mutagen_ex, path: #{inspect(project_root)}}
        ]
      end
    end
    """
  end

  defp decode_report!(stdout, exit_code, target) do
    json_line =
      stdout
      |> String.split("\n", trim: true)
      |> Enum.reverse()
      |> Enum.find(fn line ->
        trimmed = String.trim(line)

        String.starts_with?(trimmed, "{") and String.ends_with?(trimmed, "}") and
          json_parses?(trimmed)
      end)

    unless json_line do
      raise """
      no JSON report found for target #{target.name} (exit #{exit_code}).

      --- raw stdout ---
      #{stdout}
      """
    end

    :json.decode(String.trim(json_line))
  end

  # `:json.decode/1` yields `:null` for JSON null; normalize to `nil`.
  defp nullable(:null), do: nil
  defp nullable(other), do: other

  defp json_parses?(line) do
    _ = :json.decode(line)
    true
  rescue
    _ -> false
  end

  # Same clean-env contract as downstream_adoption_test: preserve PATH/HOME so
  # mix/elixir/~/.mix resolve, drop MIX_ENV (shadow compiles in :dev) and
  # MIX_TARGET.
  defp clean_env do
    [{"MIX_ENV", nil}, {"MIX_TARGET", nil}]
  end

  defp default_project_root do
    # this file: test/integration/support/self_mutation_harness.exs
    Path.expand("../../..", __DIR__)
  end
end
