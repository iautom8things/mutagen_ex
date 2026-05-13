defmodule MutagenEx.CLITest do
  @moduledoc """
  Tests for `MutagenEx.CLI.parse/1` and the `Mix.Tasks.Mutagen` dispatch
  table.

  Coverage of the scenarios in `.spec/specs/cli.spec.md`:

    * `mutagen.cli.s1` — basic single-scope/single-tests parse → Config
    * `mutagen.cli.s2` — missing `--scope` → `:missing_scope`
    * `mutagen.cli.s3` — repeated `--scope` accumulates
    * `mutagen.cli.s4` — `--timeout-ms 0` → `:invalid_timeout`
    * `mutagen.cli.s5` — `--seed 42` lands on `Config.seed` (full
      propagation to `ExUnit.configure/1` lives in S6/S5)
    * `mutagen.cli.s6` — exit code 0 path: parser succeeds, dispatch
      pipeline is invoked
    * `mutagen.cli.s7` — exit code non-zero path: pipeline raises / signals
      abort (verified by the test pipeline raising; full baseline-red
      semantics live in S2/S6)
    * `mutagen.cli.s8` — `--no-json` → `:flag_not_supported_in_v1`
    * `mutagen.cli.s9` — `--scope MutagenEx.X` → `:self_mutation_refused`

  Plus `OptionParser` edge cases: repeated `--scope`, negative integers in
  `--timeout-ms`, unknown flag, missing path for `--json`.

  Covers spec-verification stubs `mutagen.cli.v1`, `mutagen.cli.v2`,
  `mutagen.cli.v4`. The `v4` (`mix help mutagen`) stub is exercised by
  asserting `Mix.Tasks.Mutagen.@moduledoc` contains every required section.
  """

  use ExUnit.Case, async: true

  alias MutagenEx.CLI
  alias MutagenEx.Config

  describe "parse/1 — successful flag combinations (mutagen.cli.s1, s3)" do
    test "single --scope and --tests populate the Config" do
      assert {:ok, %Config{} = config} =
               CLI.parse(["--scope", "lib/foo.ex", "--tests", "test/foo_test.exs"])

      assert config.scopes == ["lib/foo.ex"]
      assert config.tests == ["test/foo_test.exs"]
      assert config.timeout_ms == 5_000
      assert config.seed == 0
      assert config.json_path == nil
    end

    # Note: scenario s3 in the spec uses `MutagenEx.Foo.bar/1` as one of the
    # repeated targets, but decision `self_mutation_refused` (post-dating the
    # scenario) makes that exact example unreachable — the self-mutation guard
    # now refuses it at parse time. The repeated-accumulation behaviour s3
    # demonstrates is still tested below using a non-self MFA target.

    test "repeated --scope (non-self) accumulates without overwriting (s3 behaviour)" do
      assert {:ok, %Config{scopes: scopes, tests: tests}} =
               CLI.parse([
                 "--scope",
                 "MyApp.Foo.bar/1",
                 "--scope",
                 "lib/baz.ex",
                 "--tests",
                 "tag:fast"
               ])

      assert scopes == ["MyApp.Foo.bar/1", "lib/baz.ex"]
      assert tests == ["tag:fast"]
    end

    test "repeated --tests accumulates targets in user-supplied order" do
      assert {:ok, %Config{tests: tests}} =
               CLI.parse([
                 "--scope",
                 "lib/foo.ex",
                 "--tests",
                 "test/a_test.exs",
                 "--tests",
                 "test/b_test.exs:42",
                 "--tests",
                 "tag:slow"
               ])

      assert tests == ["test/a_test.exs", "test/b_test.exs:42", "tag:slow"]
    end
  end

  describe "parse/1 — --timeout-ms (mutagen.cli.r3, s4)" do
    test "positive integer is stored on Config" do
      assert {:ok, %Config{timeout_ms: 10_000}} =
               CLI.parse([
                 "--scope",
                 "lib/foo.ex",
                 "--tests",
                 "test/foo_test.exs",
                 "--timeout-ms",
                 "10000"
               ])
    end

    test "default is 5000 when flag absent" do
      assert {:ok, %Config{timeout_ms: 5_000}} =
               CLI.parse(["--scope", "lib/foo.ex", "--tests", "test/foo_test.exs"])
    end

    test "zero is rejected with :invalid_timeout (s4)" do
      assert {:error, :invalid_timeout, details} =
               CLI.parse([
                 "--scope",
                 "lib/foo.ex",
                 "--tests",
                 "test/foo_test.exs",
                 "--timeout-ms",
                 "0"
               ])

      assert details.value == 0
    end

    test "negative integer is rejected with :invalid_timeout" do
      assert {:error, :invalid_timeout, details} =
               CLI.parse([
                 "--scope",
                 "lib/foo.ex",
                 "--tests",
                 "test/foo_test.exs",
                 "--timeout-ms",
                 "-1"
               ])

      assert details.value == -1
    end

    test "non-integer value is rejected with :invalid_timeout" do
      assert {:error, :invalid_timeout, details} =
               CLI.parse([
                 "--scope",
                 "lib/foo.ex",
                 "--tests",
                 "test/foo_test.exs",
                 "--timeout-ms",
                 "abc"
               ])

      # OptionParser surfaces invalid integer values via `invalid` —
      # the value comes through as-is.
      assert details.flag == "--timeout-ms"
      assert details.value == "abc"
    end
  end

  describe "parse/1 — --seed (mutagen.cli.r4, s5)" do
    test "integer value lands on Config.seed" do
      assert {:ok, %Config{seed: 42}} =
               CLI.parse([
                 "--scope",
                 "lib/foo.ex",
                 "--tests",
                 "test/foo_test.exs",
                 "--seed",
                 "42"
               ])
    end

    test "default seed is 0 when flag absent" do
      assert {:ok, %Config{seed: 0}} =
               CLI.parse(["--scope", "lib/foo.ex", "--tests", "test/foo_test.exs"])
    end

    test "negative seed is rejected with :invalid_seed" do
      assert {:error, :invalid_seed, _details} =
               CLI.parse([
                 "--scope",
                 "lib/foo.ex",
                 "--tests",
                 "test/foo_test.exs",
                 "--seed",
                 "-1"
               ])
    end
  end

  describe "parse/1 — --json (mutagen.cli.r5)" do
    test "absent flag leaves json_path nil (stdout default)" do
      assert {:ok, %Config{json_path: nil}} =
               CLI.parse(["--scope", "lib/foo.ex", "--tests", "test/foo_test.exs"])
    end

    test "path is stored on Config.json_path" do
      assert {:ok, %Config{json_path: "out/mutagen.json"}} =
               CLI.parse([
                 "--scope",
                 "lib/foo.ex",
                 "--tests",
                 "test/foo_test.exs",
                 "--json",
                 "out/mutagen.json"
               ])
    end
  end

  describe "parse/1 — missing required flags (mutagen.cli.s2)" do
    test "missing --scope yields :missing_scope (s2)" do
      assert {:error, :missing_scope, details} =
               CLI.parse(["--tests", "test/foo_test.exs"])

      assert is_binary(details.message)
    end

    test "missing --tests yields :missing_tests" do
      assert {:error, :missing_tests, details} =
               CLI.parse(["--scope", "lib/foo.ex"])

      assert is_binary(details.message)
    end

    test "completely empty argv yields :missing_scope (scope is checked first)" do
      assert {:error, :missing_scope, _} = CLI.parse([])
    end
  end

  describe "parse/1 — --no-json refusal (mutagen.cli.r7, s8)" do
    test "--no-json present yields :flag_not_supported_in_v1 (s8)" do
      assert {:error, :flag_not_supported_in_v1, details} =
               CLI.parse([
                 "--no-json",
                 "--scope",
                 "lib/foo.ex",
                 "--tests",
                 "test/foo_test.exs"
               ])

      assert details.flag == "--no-json"
    end

    test "--no-json is refused even when it would be the only invalid input" do
      # Confirms the pre-screen catches it before OptionParser's strict mode
      # could mis-handle it as an unknown boolean flag.
      assert {:error, :flag_not_supported_in_v1, _} =
               CLI.parse(["--scope", "lib/foo.ex", "--tests", "test/foo_test.exs", "--no-json"])
    end
  end

  describe "parse/1 — self-mutation refusal (mutagen.cli.r8, s9)" do
    test "--scope MutagenEx.MutationRunner yields :self_mutation_refused (s9)" do
      assert {:error, :self_mutation_refused, details} =
               CLI.parse([
                 "--scope",
                 "MutagenEx.MutationRunner",
                 "--tests",
                 "test/foo_test.exs"
               ])

      assert details.target == "MutagenEx.MutationRunner"
    end

    test "--scope MutagenEx.Foo.bar/1 (MFA shape) is refused" do
      assert {:error, :self_mutation_refused, _} =
               CLI.parse([
                 "--scope",
                 "MutagenEx.Foo.bar/1",
                 "--tests",
                 "test/foo_test.exs"
               ])
    end

    test "--scope Mix.Tasks.Mutagen is refused" do
      assert {:error, :self_mutation_refused, _} =
               CLI.parse([
                 "--scope",
                 "Mix.Tasks.Mutagen",
                 "--tests",
                 "test/foo_test.exs"
               ])
    end

    test "file-path scopes are NOT caught by the raw-string heuristic" do
      # The heuristic guards module-shaped targets only; file paths under
      # lib/mutagen_ex/ flow through to the scope resolver (S3a / pipeline
      # entry) which owns the resolution-based check.
      assert {:ok, %Config{scopes: ["lib/mutagen_ex/foo.ex"]}} =
               CLI.parse([
                 "--scope",
                 "lib/mutagen_ex/foo.ex",
                 "--tests",
                 "test/foo_test.exs"
               ])
    end

    test "non-MutagenEx module is accepted" do
      assert {:ok, %Config{scopes: ["MyApp.Foo"]}} =
               CLI.parse([
                 "--scope",
                 "MyApp.Foo",
                 "--tests",
                 "test/foo_test.exs"
               ])
    end
  end

  describe "parse/1 — unknown flags and stray args" do
    test "unknown long flag yields :unknown_flag" do
      assert {:error, :unknown_flag, details} =
               CLI.parse([
                 "--scope",
                 "lib/foo.ex",
                 "--tests",
                 "test/foo_test.exs",
                 "--bogus",
                 "x"
               ])

      assert details.flag == "--bogus"
    end

    test "stray positional argument yields :unknown_flag" do
      assert {:error, :unknown_flag, details} =
               CLI.parse([
                 "--scope",
                 "lib/foo.ex",
                 "--tests",
                 "test/foo_test.exs",
                 "stray"
               ])

      assert details.flag == "stray"
    end
  end

  describe "Mix.Tasks.Mutagen.run/2 — dispatch table (mutagen.cli.s6, s7)" do
    @tag :exit_codes
    test "successful parse invokes the pipeline collaborator with the Config (s6 happy path)" do
      this = self()

      dispatch = %{
        reporter: {__MODULE__, :capture_report},
        pipeline: {__MODULE__, :capture_pipeline}
      }

      Process.put(:capture_target, this)

      assert :ok =
               Mix.Tasks.Mutagen.run(
                 ["--scope", "lib/foo.ex", "--tests", "test/foo_test.exs", "--seed", "42"],
                 dispatch
               )

      assert_received {:pipeline_called, %Config{seed: 42, scopes: ["lib/foo.ex"]}}
      refute_received {:report_called, _, _}
    end

    @tag :exit_codes
    test "parse failure invokes the reporter collaborator and returns {:error, ...} (s2 path)" do
      this = self()

      dispatch = %{
        reporter: {__MODULE__, :capture_report},
        pipeline: {__MODULE__, :capture_pipeline}
      }

      Process.put(:capture_target, this)

      assert {:error, :missing_scope, details} =
               Mix.Tasks.Mutagen.run(["--tests", "test/foo_test.exs"], dispatch)

      assert is_binary(details.message)
      assert_received {:report_called, :missing_scope, _details}
      refute_received {:pipeline_called, _config}
    end

    @tag :exit_codes
    test "--no-json invokes the reporter with :flag_not_supported_in_v1 (s8 dispatch path)" do
      this = self()

      dispatch = %{
        reporter: {__MODULE__, :capture_report},
        pipeline: {__MODULE__, :capture_pipeline}
      }

      Process.put(:capture_target, this)

      assert {:error, :flag_not_supported_in_v1, _} =
               Mix.Tasks.Mutagen.run(
                 ["--no-json", "--scope", "lib/foo.ex", "--tests", "test/foo_test.exs"],
                 dispatch
               )

      assert_received {:report_called, :flag_not_supported_in_v1, _}
    end

    @tag :exit_codes
    test "self-mutation refusal invokes the reporter with :self_mutation_refused (s9 dispatch path)" do
      this = self()

      dispatch = %{
        reporter: {__MODULE__, :capture_report},
        pipeline: {__MODULE__, :capture_pipeline}
      }

      Process.put(:capture_target, this)

      assert {:error, :self_mutation_refused, _} =
               Mix.Tasks.Mutagen.run(
                 ["--scope", "MutagenEx.MutationRunner", "--tests", "test/foo_test.exs"],
                 dispatch
               )

      assert_received {:report_called, :self_mutation_refused, _}
    end

    @tag :exit_codes
    test "pipeline collaborator can raise to signal a non-zero outcome (s7 abort surface)" do
      # Demonstrates the seam: pipeline raises → caller observes. Full
      # baseline-red abort semantics (JSON shape, exit codes) land in
      # S2/S5/S6; here we just confirm the dispatch table exposes the seam.
      dispatch = %{
        reporter: {__MODULE__, :capture_report},
        pipeline: {__MODULE__, :raise_pipeline}
      }

      assert_raise RuntimeError, ~r/baseline-red simulation/, fn ->
        Mix.Tasks.Mutagen.run(
          ["--scope", "lib/foo.ex", "--tests", "test/foo_test.exs"],
          dispatch
        )
      end
    end
  end

  describe "Mix.Tasks.Mutagen.@moduledoc (mutagen.cli.r9, v4)" do
    # `mix help mutagen` renders @moduledoc. Asserting that every required
    # section heading is present in the moduledoc is the unit-test analogue
    # of the v4 verification stub.
    setup do
      {:docs_v1, _, _, _, %{"en" => moduledoc}, _, _} = Code.fetch_docs(Mix.Tasks.Mutagen)
      {:ok, moduledoc: moduledoc}
    end

    test "contains a Synopsis section", %{moduledoc: doc} do
      assert doc =~ ~r/##\s+Synopsis/
    end

    test "contains a Flags section", %{moduledoc: doc} do
      assert doc =~ ~r/##\s+Flags/
    end

    test "contains an Examples section", %{moduledoc: doc} do
      assert doc =~ ~r/##\s+Examples/
    end

    test "contains a Constraints section", %{moduledoc: doc} do
      assert doc =~ ~r/##\s+Constraints/
    end

    test "contains an Exit Codes section", %{moduledoc: doc} do
      assert doc =~ ~r/##\s+Exit Codes/
    end

    test "contains a Known Caveats section", %{moduledoc: doc} do
      assert doc =~ ~r/##\s+Known Caveats/
    end

    test "Caveats enumerate every required caveat from mutagen.cli.r9", %{moduledoc: doc} do
      # The r9 spec names eight required caveats; assert each one's keyword
      # appears in the moduledoc. We assert on the salient keyword rather
      # than full phrasing to keep the doc readable while still falsifying
      # if a caveat goes missing.
      caveats = [
        "use SomeModule",
        "Macro mutation",
        "Equivalent mutants",
        "content-addressed",
        "--no-json",
        "ExUnit ordering",
        "colon syntax",
        "Self-mutation"
      ]

      for keyword <- caveats do
        assert doc =~ keyword,
               "moduledoc is missing required caveat keyword: #{inspect(keyword)}"
      end
    end
  end

  # --- test helpers ---------------------------------------------------------

  @doc false
  def capture_report(reason, details) do
    send(Process.get(:capture_target), {:report_called, reason, details})
    :ok
  end

  @doc false
  def capture_pipeline(config) do
    send(Process.get(:capture_target), {:pipeline_called, config})
    :ok
  end

  @doc false
  def raise_pipeline(_config) do
    raise "baseline-red simulation"
  end
end
