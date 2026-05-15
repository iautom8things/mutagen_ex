defmodule MutagenEx.JsonReporterTest do
  @moduledoc """
  Unit tests for `MutagenEx.JsonReporter`.

  Coverage of scenarios in `.spec/specs/json_schema.spec.md`:

    * `mutagen.json_schema.s1` (r1, r2) — schema version + success shape.
    * `mutagen.json_schema.s2` (r3, r4) — mutation block subfield contract.
    * `mutagen.json_schema.s3` (r5) — abort variant has identical shape.
    * `mutagen.json_schema.s4` (r6) — `emit_report/1` returns `{iodata, exit_code}`,
      no I/O.
    * `mutagen.json_schema.s5` (r7, r8) — valid JSON round-trip + trailing
      newline.
    * Mix-task state-machine error-paths via the `:io` dispatch seam —
      the six abort exits the ticket enumerates.

  Covers spec-verification stubs `mutagen.json_schema.v1`, `v2`, `v4`.

  Tags used by `mix test --only`:
    * `:contract` — r6, r7, r8 (`v4`)
    * `:error_variants` — r5 (`v2`)
  """

  use ExUnit.Case, async: true

  alias MutagenEx.JsonReporter
  alias MutagenEx.JsonReporter.Report

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp full_report do
    %Report{
      meta: %{
        tool_version: "0.1.0",
        elixir_version: "1.19.5",
        otp_version: "28",
        exunit_seed: 0
      },
      scope: [
        %{file: "lib/foo.ex", line_range: 1..10, module: MyApp.Foo}
      ],
      tests: %{
        include: [],
        exclude: [:test],
        files: ["test/foo_test.exs"]
      },
      baseline: %{passed: 5, failed: 0, failures: []},
      coverage: %{covered_lines: %{"lib/foo.ex" => [1, 2, 3]}},
      mutation: %{
        total: 10,
        completed: 10,
        killed: 9,
        survived: 1,
        timeout: 0,
        compile_error: 0,
        kill_rate: 0.9,
        results: [],
        skipped: [],
        compile_errors: [],
        state_drift_warning: %{}
      },
      warnings: [],
      aborted: false,
      abort_reason: nil
    }
  end

  defp decode(iodata) do
    iodata
    |> IO.iodata_to_binary()
    |> :json.decode()
  end

  # ---------------------------------------------------------------------------
  # s1, r1, r2 — version literal + success shape
  # ---------------------------------------------------------------------------

  describe "emit_report/1 — success-shape (mutagen.json_schema.s1, r1, r2)" do
    test "version field equals the literal string \"1\"" do
      {iodata, _code} = JsonReporter.emit_report(full_report())
      decoded = decode(iodata)
      assert decoded["version"] == "1"
    end

    test "exit code is 0 on success" do
      {_iodata, code} = JsonReporter.emit_report(full_report())
      assert code == 0
    end

    test "aborted is false and abort_reason is null on success" do
      {iodata, _code} = JsonReporter.emit_report(full_report())
      decoded = decode(iodata)
      assert decoded["aborted"] == false
      assert decoded["abort_reason"] == :null
    end

    test "every top-level key is populated and non-null on a clean run (r2)" do
      {iodata, _code} = JsonReporter.emit_report(full_report())
      decoded = decode(iodata)

      for key <- ~w(version meta scope tests baseline coverage mutation warnings aborted) do
        refute decoded[key] == :null, "key #{key} should not be null on success"
        assert Map.has_key?(decoded, key), "key #{key} missing from success document"
      end
    end

    test "scenario s1: 9 killed of 10 sites yields kill_rate 0.9" do
      report = full_report()
      {iodata, _code} = JsonReporter.emit_report(report)
      decoded = decode(iodata)

      assert decoded["mutation"]["total"] == 10
      assert decoded["mutation"]["killed"] == 9
      assert decoded["mutation"]["survived"] == 1
      assert decoded["mutation"]["kill_rate"] == 0.9
    end
  end

  # ---------------------------------------------------------------------------
  # s2, r3, r4 — mutation block subfields
  # ---------------------------------------------------------------------------

  describe "emit_report/1 — mutation block subfields (mutagen.json_schema.s2, r3, r4)" do
    setup do
      result = %{
        id: "lib/foo.ex:12345:arith",
        file: "lib/foo.ex",
        line: 5,
        column: 7,
        mutator: :arith,
        original_ast: quote(do: 1 + 2),
        mutated_ast: quote(do: 1 - 2),
        status: :killed,
        tainted_predecessors: false,
        warnings: []
      }

      base = full_report()

      report = %Report{
        base
        | mutation: %{
            total: 4,
            completed: 4,
            killed: 3,
            survived: 1,
            timeout: 0,
            compile_error: 1,
            kill_rate: 0.75,
            results: List.duplicate(rendered_result(), 4),
            skipped: [
              %{
                site_id: "lib/foo.ex:11:arith",
                reason: :validate_refused,
                mutator: :arith,
                file: "lib/foo.ex"
              },
              %{
                site_id: "lib/foo.ex:22:case_drop",
                reason: :validate_refused,
                mutator: :case_drop,
                file: "lib/foo.ex"
              }
            ],
            compile_errors: [
              %{
                id: "lib/foo.ex:333:arith",
                file: "lib/foo.ex",
                line: 30,
                column: 5,
                mutator: :arith,
                message: "** (CompileError) bad ast"
              }
            ],
            state_drift_warning: %{}
          }
      }

      {:ok, report: report, sample_result: result}
    end

    test "mutation has total, completed, kill_rate per r3 / s2", %{report: report} do
      {iodata, _code} = JsonReporter.emit_report(report)
      decoded = decode(iodata)
      m = decoded["mutation"]

      assert m["total"] == 4
      assert m["completed"] == 4
      assert m["kill_rate"] == 0.75
    end

    test "mutation has all eleven r3 subfields", %{report: report} do
      {iodata, _code} = JsonReporter.emit_report(report)
      decoded = decode(iodata)
      m = decoded["mutation"]

      for k <- ~w(total completed killed survived timeout compile_error kill_rate
                  results skipped compile_errors state_drift_warning) do
        assert Map.has_key?(m, k), "mutation block missing required subfield #{k}"
      end
    end

    test "mutation.skipped has 2 entries; mutation.compile_errors has 1 per s2", %{report: report} do
      {iodata, _code} = JsonReporter.emit_report(report)
      decoded = decode(iodata)

      assert length(decoded["mutation"]["skipped"]) == 2
      assert length(decoded["mutation"]["compile_errors"]) == 1
    end

    test "results entry has every r4 field", %{report: report} do
      {iodata, _code} = JsonReporter.emit_report(report)
      decoded = decode(iodata)
      [r | _] = decoded["mutation"]["results"]

      for k <-
            ~w(id file line column mutator before before_source after status
               tainted_predecessors warnings) do
        assert Map.has_key?(r, k), "result entry missing required field #{k}"
      end
    end

    test "results.status is one of the four classifying outcomes", %{report: report} do
      {iodata, _code} = JsonReporter.emit_report(report)
      decoded = decode(iodata)
      [r | _] = decoded["mutation"]["results"]

      assert r["status"] in ["killed", "survived", "timeout", "error"]
    end

    test "compile_error outcomes do NOT appear in results (r4)", %{report: report} do
      {iodata, _code} = JsonReporter.emit_report(report)
      decoded = decode(iodata)

      statuses = Enum.map(decoded["mutation"]["results"], & &1["status"])

      refute "compile_error" in statuses,
             "compile_error outcomes must live in mutation.compile_errors, not results"
    end

    test "aborted is at top-level, not nested in mutation (r3)", %{report: report} do
      {iodata, _code} = JsonReporter.emit_report(report)
      decoded = decode(iodata)

      assert Map.has_key?(decoded, "aborted")
      refute Map.has_key?(decoded["mutation"], "aborted")
    end
  end

  defp rendered_result do
    %{
      id: "lib/foo.ex:abc123:arith",
      file: "lib/foo.ex",
      line: 5,
      column: 7,
      mutator: :arith,
      before: "1 + 2",
      before_source: "1 + 2",
      after: "1 - 2",
      status: :killed,
      tainted_predecessors: false,
      warnings: []
    }
  end

  # ---------------------------------------------------------------------------
  # s3, r5 — abort variant has identical schema
  # ---------------------------------------------------------------------------

  describe "emit_error/2 — abort variant (mutagen.json_schema.s3, r5)" do
    @tag :error_variants
    test "abort document has version: \"1\", aborted: true, abort_reason: \"missing_scope\"" do
      report = %Report{meta: meta_minimum()}
      {iodata, _code} = JsonReporter.emit_error(report, :missing_scope)
      decoded = decode(iodata)

      assert decoded["version"] == "1"
      assert decoded["aborted"] == true
      assert decoded["abort_reason"] == "missing_scope"
    end

    @tag :error_variants
    test "exit code is non-zero on abort" do
      report = %Report{meta: meta_minimum()}
      {_iodata, code} = JsonReporter.emit_error(report, :missing_scope)
      assert code != 0
    end

    @tag :error_variants
    test "baseline, coverage, mutation are null when those phases never ran (s3)" do
      report = %Report{meta: meta_minimum()}
      {iodata, _code} = JsonReporter.emit_error(report, :missing_scope)
      decoded = decode(iodata)

      assert decoded["baseline"] == :null
      assert decoded["coverage"] == :null
      assert decoded["mutation"] == :null
    end

    @tag :error_variants
    test "meta is populated even on early error (s3)" do
      report = %Report{meta: meta_minimum()}
      {iodata, _code} = JsonReporter.emit_error(report, :missing_scope)
      decoded = decode(iodata)

      assert decoded["meta"]["tool_version"] == "0.1.0"
      assert decoded["meta"]["elixir_version"] == "1.19.5"
    end

    @tag :error_variants
    test "every documented abort_reason atom in r5 round-trips as a string" do
      reasons = [
        :missing_scope,
        :invalid_timeout,
        :colon_syntax_unsupported,
        :module_not_found,
        :arity_required,
        :no_tests_match,
        :self_mutation_refused,
        :cover_already_running,
        :baseline_red,
        :unrecoverable_restore_failure,
        :flag_not_supported_in_v1
      ]

      for reason <- reasons do
        report = %Report{meta: meta_minimum()}
        {iodata, _code} = JsonReporter.emit_error(report, reason)
        decoded = decode(iodata)
        assert decoded["abort_reason"] == Atom.to_string(reason)
      end
    end

    @tag :error_variants
    test "every top-level key from r5 is present on an abort doc" do
      report = %Report{meta: meta_minimum()}
      {iodata, _code} = JsonReporter.emit_error(report, :missing_scope)
      decoded = decode(iodata)

      for key <-
            ~w(version meta scope tests baseline coverage mutation warnings aborted abort_reason) do
        assert Map.has_key?(decoded, key), "abort doc missing top-level key #{key}"
      end
    end

    @tag :error_variants
    test "abort document with populated baseline still emits when baseline failed (baseline_red)" do
      report = %Report{
        meta: meta_minimum(),
        baseline: %{
          "passed" => 3,
          "failed" => 1,
          "failures" => [%{"module" => "FooTest", "name" => "fails"}]
        }
      }

      {iodata, _code} = JsonReporter.emit_error(report, :baseline_red)
      decoded = decode(iodata)

      assert decoded["abort_reason"] == "baseline_red"
      assert decoded["baseline"]["failed"] == 1
      assert length(decoded["baseline"]["failures"]) == 1
    end
  end

  defp meta_minimum do
    %{
      tool_version: "0.1.0",
      elixir_version: "1.19.5",
      otp_version: "28",
      exunit_seed: 0
    }
  end

  # ---------------------------------------------------------------------------
  # s4, r6 — `{iodata, exit_code}`, no I/O
  # ---------------------------------------------------------------------------

  describe "emit_report/1 + emit_error/2 — I/O contract (mutagen.json_schema.s4, r6)" do
    @tag :contract
    test "emit_report/1 returns {iodata, exit_code}" do
      {iodata, code} = JsonReporter.emit_report(full_report())
      assert is_integer(code)
      assert is_binary(iodata) or is_list(iodata)
    end

    @tag :contract
    test "emit_error/2 returns {iodata, non_zero_exit_code}" do
      report = %Report{meta: meta_minimum()}
      {iodata, code} = JsonReporter.emit_error(report, :baseline_red)
      assert is_integer(code) and code != 0
      assert is_binary(iodata) or is_list(iodata)
    end

    @tag :contract
    test "no IO.puts, IO.write, System.halt, or File.write call appears in JsonReporter source" do
      # Deterministic surrogate for "the function makes no I/O calls":
      # parse the JsonReporter source and walk the AST looking for any
      # remote function call to the forbidden M.f shapes. The check looks
      # at AST nodes, not raw text, so module-doc mentions of
      # "IO.puts" / "System.halt" don't false-positive.
      source = File.read!("lib/mutagen_ex/json_reporter.ex")
      {:ok, ast} = Code.string_to_quoted(source)

      forbidden = [
        {IO, :puts},
        {IO, :write},
        {System, :halt},
        {File, :write},
        {File, :write!}
      ]

      offending =
        Macro.prewalk(ast, [], fn
          {{:., _, [{:__aliases__, _, mod_parts}, fun]}, _, _args} = node, acc
          when is_atom(fun) ->
            mod = Module.concat(mod_parts)

            if {mod, fun} in forbidden do
              {node, [{mod, fun} | acc]}
            else
              {node, acc}
            end

          node, acc ->
            {node, acc}
        end)
        |> elem(1)

      assert offending == [],
             "JsonReporter must not call I/O. Found: #{inspect(offending)}"
    end
  end

  # ---------------------------------------------------------------------------
  # s5, r7, r8 — valid JSON + trailing newline
  # ---------------------------------------------------------------------------

  describe "emit_report/1 — encoding contract (mutagen.json_schema.s5, r7, r8)" do
    @tag :contract
    test "encoded output round-trips through :json.decode" do
      {iodata, _code} = JsonReporter.emit_report(full_report())
      str = IO.iodata_to_binary(iodata)
      assert {:ok, decoded} = safe_decode(str)
      assert decoded["version"] == "1"
    end

    @tag :contract
    test "UTF-8 characters in source slices encode correctly" do
      base = full_report()

      report = %Report{
        base
        | mutation: %{
            total: 1,
            completed: 1,
            killed: 1,
            survived: 0,
            timeout: 0,
            compile_error: 0,
            kill_rate: 1.0,
            results: [
              %{
                id: "lib/foo.ex:abc:string",
                file: "lib/foo.ex",
                line: 1,
                column: 1,
                mutator: :string,
                before: "\"héllo\"",
                before_source: "\"héllo\"",
                after: "\"world\"",
                status: :killed,
                tainted_predecessors: false,
                warnings: []
              }
            ],
            skipped: [],
            compile_errors: [],
            state_drift_warning: %{}
          }
      }

      {iodata, _code} = JsonReporter.emit_report(report)
      str = IO.iodata_to_binary(iodata)
      decoded = decode(str)

      [r | _] = decoded["mutation"]["results"]
      assert r["before_source"] == "\"héllo\""
      refute str =~ "�", "no Unicode replacement char in the encoded document"
    end

    @tag :contract
    test "document terminates with exactly one trailing newline (r8)" do
      {iodata, _code} = JsonReporter.emit_report(full_report())
      str = IO.iodata_to_binary(iodata)

      assert String.ends_with?(str, "\n")
      refute String.ends_with?(str, "\n\n"), "trailing newline is exactly one byte"
    end

    @tag :contract
    test "abort document also terminates with exactly one trailing newline" do
      report = %Report{meta: meta_minimum()}
      {iodata, _code} = JsonReporter.emit_error(report, :missing_scope)
      str = IO.iodata_to_binary(iodata)

      assert String.ends_with?(str, "\n")
      refute String.ends_with?(str, "\n\n")
    end
  end

  defp safe_decode(str) do
    try do
      {:ok, :json.decode(str)}
    rescue
      e -> {:error, e}
    end
  end

  # ---------------------------------------------------------------------------
  # State-machine error-paths via Mix task dispatch (mutagen.cli.s7 + 6
  # error exits enumerated by the ticket)
  # ---------------------------------------------------------------------------

  describe "Mix.Tasks.Mutagen — state-machine error paths via dispatch injection" do
    setup do
      Process.put(:capture_target, self())
      :ok
    end

    @tag :exit_codes
    test "cli parse failure (missing_scope) emits abort JSON via reporter_error + io" do
      dispatch = capture_dispatch()

      assert {:aborted, :missing_scope, _report} =
               Mix.Tasks.Mutagen.run(["--tests", "test/foo_test.exs"], dispatch)

      assert_received {:io, iodata, code, _config}
      assert code != 0
      decoded = decode(iodata)
      assert decoded["abort_reason"] == "missing_scope"
      assert decoded["aborted"] == true
    end

    @tag :exit_codes
    test "scope resolution failure (module_not_found) emits abort JSON" do
      dispatch =
        capture_dispatch(
          scope: fn target, _opts ->
            {:error, :module_not_found, %{target: target, message: "no module named #{target}"}}
          end
        )

      assert {:aborted, :module_not_found, _report} =
               Mix.Tasks.Mutagen.run(
                 ["--scope", "lib/foo.ex", "--tests", "test/foo_test.exs"],
                 dispatch
               )

      assert_received {:io, iodata, _code, _config}
      decoded = decode(iodata)
      assert decoded["abort_reason"] == "module_not_found"
    end

    @tag :exit_codes
    test "test selector failure (no_tests_match) emits abort JSON" do
      dispatch =
        capture_dispatch(
          scope: &fake_scope/2,
          tests: fn _targets, _opts ->
            {:error, %{reason: :no_tests_match, target: "tag:nope"}}
          end
        )

      assert {:aborted, :no_tests_match, _report} =
               Mix.Tasks.Mutagen.run(
                 ["--scope", "lib/foo.ex", "--tests", "tag:nope"],
                 dispatch
               )

      assert_received {:io, _iodata, _code, _config}
    end

    @tag :exit_codes
    test "ast_cache failure (parse_error) emits abort JSON" do
      dispatch =
        capture_dispatch(
          scope: &fake_scope/2,
          tests: &fake_tests/2,
          ast_cache: fn _files, _opts ->
            {:error, :parse_error, %{file: "lib/foo.ex", message: "bad syntax"}}
          end
        )

      assert {:aborted, :parse_error, _report} =
               Mix.Tasks.Mutagen.run(
                 ["--scope", "lib/foo.ex", "--tests", "test/foo_test.exs"],
                 dispatch
               )

      assert_received {:io, iodata, _code, _config}
      decoded = decode(iodata)
      assert decoded["abort_reason"] == "parse_error"
    end

    @tag :exit_codes
    test "coverage phase failure (cover_already_running) emits abort JSON" do
      dispatch =
        capture_dispatch(
          scope: &fake_scope/2,
          tests: &fake_tests/2,
          ast_cache: &fake_ast_cache/2,
          coverage: fn _input ->
            {:error, :cover_already_running, %{message: "cover server up"}}
          end
        )

      assert {:aborted, :cover_already_running, _report} =
               Mix.Tasks.Mutagen.run(
                 ["--scope", "lib/foo.ex", "--tests", "test/foo_test.exs"],
                 dispatch
               )

      assert_received {:io, iodata, _code, _config}
      decoded = decode(iodata)
      assert decoded["abort_reason"] == "cover_already_running"
    end

    @tag :exit_codes
    test "baseline-red emits abort JSON with baseline.failures populated (cli.s7)" do
      dispatch =
        capture_dispatch(
          scope: &fake_scope/2,
          tests: &fake_tests/2,
          ast_cache: &fake_ast_cache/2,
          coverage: &fake_coverage/1,
          enumerator: &fake_enumerator/4,
          baseline: fn _input ->
            {:error, :baseline_red,
             %{
               passed: 3,
               failed: 1,
               failures: [{FooTest, "fails"}]
             }}
          end
        )

      assert {:aborted, :baseline_red, _report} =
               Mix.Tasks.Mutagen.run(
                 ["--scope", "lib/foo.ex", "--tests", "test/foo_test.exs"],
                 dispatch
               )

      assert_received {:io, iodata, code, _config}
      assert code != 0
      decoded = decode(iodata)
      assert decoded["abort_reason"] == "baseline_red"
      assert decoded["baseline"]["failed"] == 1
      assert [%{"module" => "FooTest", "name" => "fails"}] = decoded["baseline"]["failures"]
    end

    @tag :exit_codes
    test "mutation runner failure (unrecoverable_restore_failure) emits abort JSON" do
      dispatch =
        capture_dispatch(
          scope: &fake_scope/2,
          tests: &fake_tests/2,
          ast_cache: &fake_ast_cache/2,
          coverage: &fake_coverage/1,
          enumerator: &fake_enumerator/4,
          baseline: &fake_baseline/1,
          mutation: fn _input ->
            {:error, :unrecoverable_restore_failure,
             %{site_id: "lib/foo.ex:abc:arith", message: "restore failed"}}
          end
        )

      assert {:aborted, :unrecoverable_restore_failure, _report} =
               Mix.Tasks.Mutagen.run(
                 ["--scope", "lib/foo.ex", "--tests", "test/foo_test.exs"],
                 dispatch
               )

      assert_received {:io, _iodata, _code, _config}
    end

    @tag :exit_codes
    test "happy path: every phase passes → success JSON + exit code 0 (cli.s6)" do
      dispatch =
        capture_dispatch(
          scope: &fake_scope/2,
          tests: &fake_tests/2,
          ast_cache: &fake_ast_cache/2,
          coverage: &fake_coverage/1,
          enumerator: &fake_enumerator/4,
          baseline: &fake_baseline/1,
          mutation: &fake_mutation/1
        )

      assert :ok =
               Mix.Tasks.Mutagen.run(
                 ["--scope", "lib/foo.ex", "--tests", "test/foo_test.exs"],
                 dispatch
               )

      assert_received {:io, iodata, 0, _config}
      decoded = decode(iodata)
      assert decoded["aborted"] == false
      assert decoded["version"] == "1"
    end

    @tag :exit_codes
    test "mix task hands MutationRunner a populated test_modules derived from test_filter.files (mutagen-wrd.12)" do
      # Regression test for mutagen-wrd.12. Before the fix the mix task
      # passed `test_modules: []` to MutationRunner, so MutationLoop's
      # per-site `add_module/2` loop was a no-op and every mutation was
      # classified `:survived` regardless of whether the cited tests
      # would actually kill them. The fix derives `test_modules` from
      # `test_filter.files` via `MutagenEx.TestModuleDiscovery.discover/1`.

      tmp_test =
        Path.join(
          System.tmp_dir!(),
          "mutagen_ex_phase_mut_#{System.unique_integer([:positive])}_test.exs"
        )

      File.write!(tmp_test, """
      defmodule Mutagen.Phase.MutationCaptureTest do
        use ExUnit.Case
        test "x", do: :ok
      end
      """)

      on_exit(fn -> File.rm(tmp_test) end)

      tests_returning_real_file = fn _targets, _opts ->
        {:ok,
         %MutagenEx.TestSelector.TestFilter{
           include: [],
           exclude: [],
           files: [tmp_test]
         }}
      end

      mutation_capturing_input = fn input ->
        send(Process.get(:capture_target), {:mutation_input, input})
        fake_mutation(input)
      end

      dispatch =
        capture_dispatch(
          scope: &fake_scope/2,
          tests: tests_returning_real_file,
          ast_cache: &fake_ast_cache/2,
          coverage: &fake_coverage/1,
          enumerator: &fake_enumerator/4,
          baseline: &fake_baseline/1,
          mutation: mutation_capturing_input
        )

      assert :ok =
               Mix.Tasks.Mutagen.run(
                 ["--scope", "lib/foo.ex", "--tests", tmp_test],
                 dispatch
               )

      assert_received {:mutation_input, mutation_input}

      # The test_modules payload must (a) not be empty, (b) include the
      # exact module declared in the cited test file, (c) carry the
      # ExUnit.Server.add_module/2 cfg shape (`%{async?: false,
      # group: nil, parameterize: nil}`). Each of these would have been
      # false before mutagen-wrd.12 fixed phase_mutation/7.
      assert is_list(mutation_input.test_modules)

      refute mutation_input.test_modules == [],
             "test_modules must be derived from test_filter.files, not hardcoded to []"

      assert {Mutagen.Phase.MutationCaptureTest, %{async?: false, group: nil, parameterize: nil}} in mutation_input.test_modules
    end
  end

  # ---------------------------------------------------------------------------
  # Fake phase implementations for state-machine tests
  # ---------------------------------------------------------------------------

  defp capture_dispatch(overrides \\ []) do
    # Each phase has a different arity, so we keep one process-dict slot
    # per *phase* keyed by the dispatch key. The trampoline functions
    # below pick the right slot.
    Enum.each(overrides, fn {k, fun} -> Process.put({:phase_fun, k}, fun) end)

    base = %{
      io: {__MODULE__, :capture_io}
    }

    Enum.reduce(overrides, base, fn {k, _fun}, acc ->
      Map.put(acc, k, phase_mfa(k))
    end)
  end

  # Map a phase key to a {module, function} pair the dispatch table
  # expects. Each phase has a dedicated trampoline that knows the right
  # phase key to read from the process dictionary.
  defp phase_mfa(:scope), do: {__MODULE__, :__phase_scope__}
  defp phase_mfa(:tests), do: {__MODULE__, :__phase_tests__}
  defp phase_mfa(:ast_cache), do: {__MODULE__, :__phase_ast_cache__}
  defp phase_mfa(:coverage), do: {__MODULE__, :__phase_coverage__}
  defp phase_mfa(:enumerator), do: {__MODULE__, :__phase_enumerator__}
  defp phase_mfa(:baseline), do: {__MODULE__, :__phase_baseline__}
  defp phase_mfa(:mutation), do: {__MODULE__, :__phase_mutation__}

  @doc false
  def __phase_scope__(target, opts), do: apply(Process.get({:phase_fun, :scope}), [target, opts])

  @doc false
  def __phase_tests__(targets, opts),
    do: apply(Process.get({:phase_fun, :tests}), [targets, opts])

  @doc false
  def __phase_ast_cache__(files, opts),
    do: apply(Process.get({:phase_fun, :ast_cache}), [files, opts])

  @doc false
  def __phase_coverage__(input), do: apply(Process.get({:phase_fun, :coverage}), [input])

  @doc false
  def __phase_enumerator__(cache, scope, covered, opts),
    do: apply(Process.get({:phase_fun, :enumerator}), [cache, scope, covered, opts])

  @doc false
  def __phase_baseline__(input), do: apply(Process.get({:phase_fun, :baseline}), [input])

  @doc false
  def __phase_mutation__(input), do: apply(Process.get({:phase_fun, :mutation}), [input])

  @doc false
  def capture_io(iodata, code, config) do
    send(Process.get(:capture_target), {:io, iodata, code, config})
    :ok
  end

  # --- Fake phase return shapes -----------------------------------------------

  defp fake_scope(_target, _opts) do
    {:ok,
     [%MutagenEx.ScopeResolver.Scope{file: "lib/foo.ex", line_range: 1..10, module: MyApp.Foo}]}
  end

  defp fake_tests(_targets, _opts) do
    {:ok,
     %MutagenEx.TestSelector.TestFilter{
       include: [],
       exclude: [:test],
       files: ["test/foo_test.exs"]
     }}
  end

  defp fake_ast_cache(_files, _opts) do
    {:ok, %{"lib/foo.ex" => {quote(do: :ok), "def foo, do: :ok"}}}
  end

  defp fake_coverage(_input) do
    {:ok,
     %{
       covered_lines: %{"lib/foo.ex" => MapSet.new([1, 2, 3])},
       instrumented_modules: [MyApp.Foo]
     }}
  end

  defp fake_enumerator(_ast_cache, _scope_records, _covered, _opts) do
    %{sites: [], skipped: [], warnings: []}
  end

  defp fake_baseline(_input) do
    {:ok, %{passed: 5, failed: 0, failures: [], warnings: []}}
  end

  defp fake_mutation(_input) do
    {:ok,
     %{
       results: [],
       compile_errors: [],
       state_drift_warning: %{},
       warnings: []
     }}
  end
end
