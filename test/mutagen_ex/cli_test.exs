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

  describe "parse/1 — --json path safety (mutagen.cli.r10, s10a, s10b)" do
    test "path with `..` is rejected at parse time as :unsafe_json_path (s10a)" do
      assert {:error, :unsafe_json_path, details} =
               CLI.parse([
                 "--scope",
                 "lib/foo.ex",
                 "--tests",
                 "test/foo_test.exs",
                 "--json",
                 "../../etc/passwd"
               ])

      assert details.variant == :traversal
      assert details.path == "../../etc/passwd"
      assert is_binary(details.message)
    end

    test "absolute path with `..` is rejected at parse time as :unsafe_json_path" do
      assert {:error, :unsafe_json_path, details} =
               CLI.parse([
                 "--scope",
                 "lib/foo.ex",
                 "--tests",
                 "test/foo_test.exs",
                 "--json",
                 "/tmp/../etc/passwd"
               ])

      assert details.variant == :traversal
    end

    test "path with embedded NUL byte is rejected at parse time (s10b)" do
      nul_path = "out/report" <> <<0>> <> ".json"

      assert {:error, :unsafe_json_path, details} =
               CLI.parse([
                 "--scope",
                 "lib/foo.ex",
                 "--tests",
                 "test/foo_test.exs",
                 "--json",
                 nul_path
               ])

      assert details.variant == :nul_byte
      assert details.path == nul_path
    end

    test "literal-safe path passes parse (FS canonicalisation happens later)" do
      # The CLI parser only does pure-string checks. A path that POINTS
      # OUTSIDE the project root literally (e.g. `/tmp/foo.json`) is fine
      # at parse time — the inside-root check runs in the mix task before
      # any mutation phase.
      assert {:ok, %Config{json_path: "/tmp/foo.json"}} =
               CLI.parse([
                 "--scope",
                 "lib/foo.ex",
                 "--tests",
                 "test/foo_test.exs",
                 "--json",
                 "/tmp/foo.json"
               ])
    end
  end

  describe "parse/1 — --unsafe-json-outside-project (mutagen.cli.r10)" do
    test "flag absent leaves Config.unsafe_json_outside_project at false" do
      assert {:ok, %Config{unsafe_json_outside_project: false}} =
               CLI.parse(["--scope", "lib/foo.ex", "--tests", "test/foo_test.exs"])
    end

    test "flag present sets Config.unsafe_json_outside_project to true" do
      assert {:ok, %Config{unsafe_json_outside_project: true}} =
               CLI.parse([
                 "--scope",
                 "lib/foo.ex",
                 "--tests",
                 "test/foo_test.exs",
                 "--unsafe-json-outside-project"
               ])
    end

    test "flag is orthogonal to --json (can be passed alone without --json)" do
      # The escape hatch only has effect when `--json` is also given.
      # Setting it without `--json` is harmless — the flag still lands
      # on Config.
      assert {:ok, %Config{json_path: nil, unsafe_json_outside_project: true}} =
               CLI.parse([
                 "--scope",
                 "lib/foo.ex",
                 "--tests",
                 "test/foo_test.exs",
                 "--unsafe-json-outside-project"
               ])
    end
  end

  describe "parse/1 — --max-concurrency / --stream / --no-progress (bw mutagen-wrd.30)" do
    test "--max-concurrency 4 lands on Config" do
      assert {:ok, %Config{max_concurrency: 4}} =
               CLI.parse([
                 "--scope",
                 "lib/foo.ex",
                 "--tests",
                 "test/foo_test.exs",
                 "--max-concurrency",
                 "4"
               ])
    end

    test "--max-concurrency default is nil (Mix task resolves to schedulers_online)" do
      assert {:ok, %Config{max_concurrency: nil}} =
               CLI.parse(["--scope", "lib/foo.ex", "--tests", "test/foo_test.exs"])
    end

    test "--max-concurrency 0 is rejected with :invalid_max_concurrency" do
      assert {:error, :invalid_max_concurrency, details} =
               CLI.parse([
                 "--scope",
                 "lib/foo.ex",
                 "--tests",
                 "test/foo_test.exs",
                 "--max-concurrency",
                 "0"
               ])

      assert details.value == 0
    end

    test "--max-concurrency -2 is rejected with :invalid_max_concurrency" do
      assert {:error, :invalid_max_concurrency, _} =
               CLI.parse([
                 "--scope",
                 "lib/foo.ex",
                 "--tests",
                 "test/foo_test.exs",
                 "--max-concurrency",
                 "-2"
               ])
    end

    test "--max-concurrency non-integer surfaces :invalid_max_concurrency" do
      assert {:error, :invalid_max_concurrency, details} =
               CLI.parse([
                 "--scope",
                 "lib/foo.ex",
                 "--tests",
                 "test/foo_test.exs",
                 "--max-concurrency",
                 "many"
               ])

      assert details.flag == "--max-concurrency"
    end

    test "--stream sets Config.stream true; default false" do
      assert {:ok, %Config{stream: false}} =
               CLI.parse(["--scope", "lib/foo.ex", "--tests", "test/foo_test.exs"])

      assert {:ok, %Config{stream: true}} =
               CLI.parse([
                 "--scope",
                 "lib/foo.ex",
                 "--tests",
                 "test/foo_test.exs",
                 "--stream"
               ])
    end

    test "--no-progress sets Config.progress :off; default :auto" do
      assert {:ok, %Config{progress: :auto}} =
               CLI.parse(["--scope", "lib/foo.ex", "--tests", "test/foo_test.exs"])

      assert {:ok, %Config{progress: :off}} =
               CLI.parse([
                 "--scope",
                 "lib/foo.ex",
                 "--tests",
                 "test/foo_test.exs",
                 "--no-progress"
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

  describe "parse/1 — tag:NAME charset gate (mutagen.cli.r11, s11, s12)" do
    @describetag :tag_charset

    test "tag:slow is accepted (canonical lowercase atom name, s12)" do
      # `slow` matches the charset and flows through unchanged.
      assert {:ok, %Config{tests: ["tag:slow"]}} =
               CLI.parse(["--scope", "lib/foo.ex", "--tests", "tag:slow"])
    end

    test "tag:integration_smoke is accepted (underscores and digits allowed)" do
      assert {:ok, %Config{tests: ["tag:integration_smoke"]}} =
               CLI.parse(["--scope", "lib/foo.ex", "--tests", "tag:integration_smoke"])

      assert {:ok, %Config{tests: ["tag:slow_1"]}} =
               CLI.parse(["--scope", "lib/foo.ex", "--tests", "tag:slow_1"])
    end

    test "tag:$(uuidgen)-shaped target is rejected (s11)" do
      # UUIDs contain `-` which the charset does not admit.
      uuid_like = "tag:550e8400-e29b-41d4-a716-446655440000"

      assert {:error, :invalid_tag_name, details} =
               CLI.parse(["--scope", "lib/foo.ex", "--tests", uuid_like])

      assert details.target == uuid_like
      assert details.flag == "--tests"
      assert is_binary(details.message)
    end

    test "tag with leading uppercase is rejected" do
      assert {:error, :invalid_tag_name, _} =
               CLI.parse(["--scope", "lib/foo.ex", "--tests", "tag:Slow"])
    end

    test "tag starting with a digit is rejected" do
      assert {:error, :invalid_tag_name, _} =
               CLI.parse(["--scope", "lib/foo.ex", "--tests", "tag:1slow"])
    end

    test "tag with `?` suffix is rejected (charset doesn't admit it)" do
      assert {:error, :invalid_tag_name, _} =
               CLI.parse(["--scope", "lib/foo.ex", "--tests", "tag:slow?"])
    end

    test "tag longer than 64 chars is rejected" do
      too_long = "tag:" <> String.duplicate("a", 65)

      assert {:error, :invalid_tag_name, _} =
               CLI.parse(["--scope", "lib/foo.ex", "--tests", too_long])
    end

    test "tag exactly 64 chars is accepted (boundary)" do
      sixty_four = "tag:" <> String.duplicate("a", 64)

      assert {:ok, %Config{tests: [^sixty_four]}} =
               CLI.parse(["--scope", "lib/foo.ex", "--tests", sixty_four])
    end

    test "empty tag (tag:) does not match the file-path branch and is rejected" do
      # "tag:" with empty name does not match the regex (must start with [a-z]).
      assert {:error, :invalid_tag_name, _} =
               CLI.parse(["--scope", "lib/foo.ex", "--tests", "tag:"])
    end

    test "non-tag --tests targets are NOT gated by the charset" do
      # File paths and file:line targets bypass the gate entirely.
      assert {:ok, %Config{tests: ["test/foo_test.exs"]}} =
               CLI.parse(["--scope", "lib/foo.ex", "--tests", "test/foo_test.exs"])

      assert {:ok, %Config{tests: ["test/Foo-Bar_test.exs:42"]}} =
               CLI.parse(["--scope", "lib/foo.ex", "--tests", "test/Foo-Bar_test.exs:42"])
    end

    test "charset rejection fires before any atom path (none of the rejected names become atoms)" do
      # The fundamental contract of r11: a rejected tag target must not
      # cause atom registration. Pre-fix, the downstream selector would
      # `String.to_atom/1` each rejected name; with the gate in place,
      # parsing stops before any atom path. The falsification is
      # structural: AFTER the loop, NONE of the N rejected name parts
      # are registered atoms.
      n = 50

      probes =
        for i <- 1..n do
          # Embed `-` so the charset gate rejects it (the regex doesn't
          # admit `-`). The integer keeps each name distinct.
          part = "bad_for_charset_#{System.unique_integer([:positive])}_#{i}"
          name_with_dash = "x-" <> part
          {name_with_dash, "tag:" <> name_with_dash}
        end

      for {_name, full_target} <- probes do
        assert {:error, :invalid_tag_name, _} =
                 CLI.parse(["--scope", "lib/foo.ex", "--tests", full_target])
      end

      # Falsification: none of the N rejected `tag:NAME` parts became
      # atoms. Pre-fix code would have called `String.to_atom(name)`
      # downstream and registered all N.
      for {name, _full} <- probes do
        try do
          existing = :erlang.binary_to_existing_atom(name, :utf8)

          flunk(
            "rejected tag name #{inspect(name)} became registered atom " <>
              "#{inspect(existing)} — gate must short-circuit before atom resolution"
          )
        rescue
          ArgumentError -> :ok
        end
      end
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

  describe "parse/1 — --scope/--tests repetition cap (mutagen.cli.r12)" do
    # The cap is structural: parse refuses BEFORE any filesystem touch.
    # 100 is allowed; 101 is refused. We don't bother varying the count
    # — boundary + over-boundary is enough to falsify a "no cap" or
    # "off-by-one" regression.

    test "exactly 100 --scope occurrences parse cleanly (cap boundary)" do
      argv =
        Enum.flat_map(1..100, fn n -> ["--scope", "lib/foo_#{n}.ex"] end) ++
          ["--tests", "test/foo_test.exs"]

      assert {:ok, %Config{scopes: scopes}} = CLI.parse(argv)
      assert length(scopes) == 100
    end

    test "101 --scope occurrences are refused with :too_many_targets" do
      argv =
        Enum.flat_map(1..101, fn n -> ["--scope", "lib/foo_#{n}.ex"] end) ++
          ["--tests", "test/foo_test.exs"]

      assert {:error, :too_many_targets, details} = CLI.parse(argv)
      assert details.flag == "--scope"
      assert details.kind == :scope
      assert details.cap == 100
      assert details.count == 101
      assert is_binary(details.message)
    end

    test "101 --tests occurrences are refused with :too_many_targets" do
      argv =
        ["--scope", "lib/foo.ex"] ++
          Enum.flat_map(1..101, fn n -> ["--tests", "test/t_#{n}_test.exs"] end)

      assert {:error, :too_many_targets, details} = CLI.parse(argv)
      assert details.flag == "--tests"
      assert details.kind == :tests
      assert details.cap == 100
      assert details.count == 101
    end

    test "501 --scope occurrences still resolve to :too_many_targets, not OOM" do
      # Falsifies "cap was a comment, not enforced". 501 is well past the
      # cap; if the cap weren't honoured we'd materialise a 501-element
      # scope list. The assertion is that parse halts at the cap check.
      argv =
        Enum.flat_map(1..501, fn n -> ["--scope", "lib/foo_#{n}.ex"] end) ++
          ["--tests", "test/foo_test.exs"]

      assert {:error, :too_many_targets, details} = CLI.parse(argv)
      assert details.count == 501
    end
  end

  describe "parse/1 — --max-sites (mutagen.cli.r12)" do
    test "default --max-sites is 10_000" do
      assert {:ok, %Config{max_sites: 10_000}} =
               CLI.parse(["--scope", "lib/foo.ex", "--tests", "test/foo_test.exs"])
    end

    test "positive integer lands on Config.max_sites" do
      assert {:ok, %Config{max_sites: 250}} =
               CLI.parse([
                 "--scope",
                 "lib/foo.ex",
                 "--tests",
                 "test/foo_test.exs",
                 "--max-sites",
                 "250"
               ])
    end

    test "zero is rejected with :invalid_max_sites" do
      assert {:error, :invalid_max_sites, details} =
               CLI.parse([
                 "--scope",
                 "lib/foo.ex",
                 "--tests",
                 "test/foo_test.exs",
                 "--max-sites",
                 "0"
               ])

      assert details.value == 0
    end

    test "negative value is rejected with :invalid_max_sites" do
      assert {:error, :invalid_max_sites, _details} =
               CLI.parse([
                 "--scope",
                 "lib/foo.ex",
                 "--tests",
                 "test/foo_test.exs",
                 "--max-sites",
                 "-1"
               ])
    end

    test "non-integer value is rejected with :invalid_max_sites" do
      assert {:error, :invalid_max_sites, details} =
               CLI.parse([
                 "--scope",
                 "lib/foo.ex",
                 "--tests",
                 "test/foo_test.exs",
                 "--max-sites",
                 "abc"
               ])

      assert details.flag == "--max-sites"
    end
  end

  describe "parse/1 — --budget-ms (mutagen.cli.r13)" do
    test "absent flag leaves Config.budget_ms == nil (unbounded)" do
      assert {:ok, %Config{budget_ms: nil}} =
               CLI.parse(["--scope", "lib/foo.ex", "--tests", "test/foo_test.exs"])
    end

    test "positive integer lands on Config.budget_ms" do
      assert {:ok, %Config{budget_ms: 30_000}} =
               CLI.parse([
                 "--scope",
                 "lib/foo.ex",
                 "--tests",
                 "test/foo_test.exs",
                 "--budget-ms",
                 "30000"
               ])
    end

    test "zero is rejected with :invalid_budget_ms" do
      assert {:error, :invalid_budget_ms, details} =
               CLI.parse([
                 "--scope",
                 "lib/foo.ex",
                 "--tests",
                 "test/foo_test.exs",
                 "--budget-ms",
                 "0"
               ])

      assert details.value == 0
    end

    test "negative value is rejected with :invalid_budget_ms" do
      assert {:error, :invalid_budget_ms, _details} =
               CLI.parse([
                 "--scope",
                 "lib/foo.ex",
                 "--tests",
                 "test/foo_test.exs",
                 "--budget-ms",
                 "-100"
               ])
    end

    test "non-integer value is rejected with :invalid_budget_ms" do
      assert {:error, :invalid_budget_ms, details} =
               CLI.parse([
                 "--scope",
                 "lib/foo.ex",
                 "--tests",
                 "test/foo_test.exs",
                 "--budget-ms",
                 "abc"
               ])

      assert details.flag == "--budget-ms"
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

  describe "Mix.Tasks.Mutagen — parse-time --json safety (mutagen.cli.r10, s10a)" do
    # Pure parse-time checks (no FS), safe to run async. The FS-touching
    # tests for s10c/s10d/s10e live in MutagenEx.JsonCanonicalisationTest
    # which is async: false because it uses File.cd!/2.

    setup do
      Process.put(:capture_target, self())
      :ok
    end

    @tag :exit_codes
    test "parse-time `..` traversal emits abort JSON (s10a)" do
      dispatch = %{
        scope: __MODULE__.PhaseStubs.Scope,
        io: __MODULE__.PhaseStubs.Io
      }

      Process.put({:phase_fun, :scope}, &fail_scope/2)

      assert {:aborted, :unsafe_json_path, _report} =
               Mix.Tasks.Mutagen.run(
                 [
                   "--scope",
                   "lib/foo.ex",
                   "--tests",
                   "test/foo_test.exs",
                   "--json",
                   "../etc/passwd"
                 ],
                 dispatch
               )

      assert_received {:io, iodata, code, _config}
      assert code != 0

      decoded =
        iodata
        |> IO.iodata_to_binary()
        |> :json.decode()

      assert decoded["abort_reason"] == "unsafe_json_path"
      assert decoded["aborted"] == true
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
      # The r9 spec names the required caveats; assert each one's keyword
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
        "Self-mutation",
        # mutagen.cli.r11 — tag:NAME charset gate
        "tag:NAME"
      ]

      for keyword <- caveats do
        assert doc =~ keyword,
               "moduledoc is missing required caveat keyword: #{inspect(keyword)}"
      end
    end

    test "Caveats mention input/output caps (mutagen.cli.r12/r13)", %{moduledoc: doc} do
      # Falsifies regression where caps section is dropped from
      # moduledoc. We don't require exact wording; the salient flag
      # names and reason atoms must appear.
      for keyword <- [
            "--max-sites",
            "--budget-ms",
            "too_many_targets",
            "truncated"
          ] do
        assert doc =~ keyword,
               "moduledoc is missing required caps keyword: #{inspect(keyword)}"
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

  # --- helpers for the parse-time --json safety test -------------------------
  #
  # Per bw mutagen-wrd.33, the Mix task dispatches via plain module
  # atoms — tests swap modules, not `{module, function}` tuples. The
  # closure-injection slot is keyed by phase atom; the
  # PhaseStubs.* modules below read it back at dispatch time.

  defmodule PhaseStubs.Scope do
    @moduledoc false
    @behaviour MutagenEx.Pipeline.ScopeFacade

    @impl MutagenEx.Pipeline.ScopeFacade
    def resolve(target, opts) do
      apply(Process.get({:phase_fun, :scope}), [target, opts])
    end
  end

  defmodule PhaseStubs.Io do
    @moduledoc false
    @behaviour MutagenEx.Pipeline.IoFacade

    @impl MutagenEx.Pipeline.IoFacade
    def emit(iodata, code, config) do
      send(Process.get(:capture_target), {:io, iodata, code, config})
      :ok
    end
  end

  # A scope collaborator that always fails — drives the pipeline far
  # enough past canonicalisation that `:io` fires with the threaded
  # Config. The parse-time --json safety test uses this as a defensive
  # fallback, though the abort there fires before scope is even reached.
  defp fail_scope(target, _opts) do
    {:error, :module_not_found, %{target: target, message: "fake-scope refusal (test harness)"}}
  end
end
