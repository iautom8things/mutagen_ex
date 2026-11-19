defmodule MutagenEx.Integration.HostSetupTest do
  use ExUnit.Case, async: false

  @moduletag :host_setup_integration
  @moduletag timeout: to_timeout(minute: 3)

  @project_root Path.expand("../..", __DIR__)
  @fixture Path.join(@project_root, "test/fixtures/host_setup_project")
  @scope "lib/host_setup_fixture/orders.ex"
  @tests "checks/orders_test.exs"

  setup_all do
    dependency = prepare_host(mutagen_path: @project_root)
    archive = prepare_host(partition: "2")
    archive_path = Path.join(archive.dir, "mutagen_ex.ez")

    Mix.Task.reenable("archive.build")
    Mix.Task.run("archive.build", ["-o", archive_path])
    mix!(archive, ["archive.install", "--force", archive_path])

    {:ok, dependency: dependency, archive: archive}
  end

  describe "path dependency" do
    @tag spec: ["mutagen.cli.r14", "mutagen.cli.r20", "mutagen.cli.r22"]
    test "runs the host helper and sandbox tests across mutation cycles", %{dependency: host} do
      assert_host_run(host)
    end

    @tag spec: ["mutagen.mutation_pipeline.r25", "mutagen.mutation_pipeline.r27"]
    test "matches mix test Sandbox ownership and nested case order on every pass", %{
      dependency: host
    } do
      helper_path = "checks/test_helper.exs"
      helper = File.read!(Path.join(host.dir, helper_path))
      trace = Path.join(host.dir, "sandbox.log")

      # Mix can start the inner async case before the enclosing module compiles.
      tests = """
      defmodule HostSetupFixture.SandboxProbe do
        import ExUnit.Assertions
        alias HostSetupFixture.Repo

        def record(case_name, async) do
          assert %{rows: [[1]]} = Repo.query!("SELECT 1")

          caller = self()
          spawn(fn ->
            mode =
              try do
                Repo.query!("SELECT 1")
                :shared
              rescue
                DBConnection.OwnershipError -> :isolated
              end

            send(caller, {:sandbox_mode, mode})
          end)

          assert_receive {:sandbox_mode, mode}, 1_000
          File.write!("sandbox.log", "\#{case_name} \#{async} \#{mode}\\n", [:append])
        end
      end

      defmodule HostSetupFixture.SandboxOrderTest do
        use HostSetupFixture.DataCase, async: true
        import Mox
        alias HostSetupFixture.{Order, Orders, PricingMock, Repo, SandboxProbe}

        defmodule Inner do
          use HostSetupFixture.DataCase, async: true
          @tag :pricing
          test "inner", tags do
            HostSetupFixture.SandboxProbe.record(:inner, tags.async)
          end
        end

        @tag :pricing
        test "outer", tags do
          SandboxProbe.record(:outer, tags.async)
          expect(PricingMock, :rate, fn -> 4 end)
          order = Repo.insert!(%Order{quantity: 3})
          assert Orders.price(order.id) == 14
        end
      end
      """

      with_file(host, @tests, tests, fn ->
        File.write!(trace, "")

        with_file(host, helper_path, String.split(helper, "\n", parts: 2) |> List.last(), fn ->
          mix!(host, ["test", @tests, "--max-cases", "1", "--seed", "0"])
        end)

        mix_test = File.read!(trace)
        assert mix_test == "inner true isolated\nouter true isolated\n"
        File.write!(trace, "")

        {stdout, 0} = mutate(host, [])
        report = decode_report(stdout)
        assert %{"baseline" => %{"passed" => 2}, "mutation" => %{"total" => total}} = report
        assert total > 0
        assert File.read!(trace) == String.duplicate(mix_test, 2 + total)
      end)
    end
  end

  describe "installed archive" do
    @tag spec: ["mutagen.cli.r14", "mutagen.cli.r16", "mutagen.cli.r20", "mutagen.cli.r22"]
    test "runs the same host setup with a partitioned database", %{archive: host} do
      assert_host_run(host)
    end

    @tag spec: "mutagen.test_selection.r8"
    test "an explicit line selection narrows the helper's includes", %{archive: host} do
      helper_path = "checks/test_helper.exs"
      helper = File.read!(Path.join(host.dir, helper_path))

      line =
        host.dir
        |> Path.join(@tests)
        |> File.stream!()
        |> Enum.find_index(&String.contains?(&1, ~s(test "prices an order)))

      with_file(host, helper_path, helper <> "\nExUnit.configure(include: [:load])\n", fn ->
        assert_host_run(host, "#{@tests}:#{line + 1}")
      end)
    end

    @tag spec: "mutagen.cli.r18"
    test "refuses the default dev environment before attempting host startup", %{archive: host} do
      host = put_env(host, "MIX_ENV", nil)
      assert abort(host, "invalid_mix_env") =~ "current Mix environment: dev"
    end

    @tag spec: ["mutagen.cli.r5", "mutagen.cli.r19"]
    test "reports an unreachable database as one JSON value on stdout and in a file", %{
      archive: host
    } do
      {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
      {:ok, port} = :inet.port(socket)
      :ok = :gen_tcp.close(socket)

      host =
        host
        |> put_env("HOST_SETUP_DB_HOST", "127.0.0.1")
        |> put_env("HOST_SETUP_DB_PORT", Integer.to_string(port))

      assert abort(host, "host_app_start_failed", ["--no-test-alias"]) =~
               "Could not start application"

      {stdout, status} =
        mutate(host, ["--no-test-alias", "--include-host-output", "--json", "host-error.json"])

      assert status != 0
      assert stdout == ""
      report = File.read!(Path.join(host.dir, "host-error.json"))
      assert abort_message(report, "host_app_start_failed") =~ "Could not start application"

      assert :json.decode(report)["details"]["note"] ==
               "Stderr may carry unredacted host output. Do not publish it as a CI artifact."
    end

    @tag spec: ["mutagen.cli.r16", "mutagen.cli.r19", "mutagen.cli.r28"]
    test "reports a report module missing from the installed archive", %{archive: host} do
      for module <- ["MutagenEx.JsonPath", "MutagenEx.JsonStreamer"] do
        [beam] = Path.wildcard(Path.join(host.dir, "archives/**/ebin/Elixir.#{module}.beam"))
        relative = Path.relative_to(beam, host.dir)

        with_file(host, relative, nil, fn ->
          assert abort(host, "runtime_load_failed", ["--stream"]) =~ "could not load #{module}"
        end)
      end
    end

    @tag spec: "mutagen.cli.r19"
    test "reports a host loadpaths failure", %{archive: host} do
      mixfile = File.read!(Path.join(host.dir, "mix.exs"))

      with_file(
        host,
        "mix.exs",
        String.replace(mixfile, "deps: deps()", """
        deps: [{:missing_host_dep, path: "missing"} | deps()]
        """),
        fn ->
          assert abort(host, "host_loadpaths_failed") =~ "errors on dependencies"
        end
      )
    end

    @tag spec: "mutagen.cli.r19"
    test "reports a host compiler error", %{archive: host} do
      with_file(host, @scope, "defmodule HostSetupFixture.Orders do", fn ->
        assert abort(host, "host_compile_failed") =~ "token missing"
      end)
    end

    @tag spec: "mutagen.cli.r19"
    test "reports a missing helper", %{archive: host} do
      with_file(host, "checks/test_helper.exs", nil, fn ->
        assert abort(host, "test_helper_load_failed", ["--stream"]) =~ "checks/test_helper.exs"
      end)
    end

    @tag spec: ["mutagen.cli.r19", "mutagen.json_schema.r11"]
    test "reports a raising helper with sanitized details", %{archive: host} do
      config = "config/runtime.exs"
      original = File.read!(Path.join(host.dir, config))

      with_file(
        host,
        config,
        original <> ~s(\nconfig :mutagen_ex, redact: ["FIXTURE_SECRET"]\n),
        fn ->
          with_file(
            host,
            "checks/test_helper.exs",
            ~s(raise "helper did not start: FIXTURE_SECRET"),
            fn ->
              assert abort(host, "test_helper_load_failed") == "helper did not start: [REDACTED]"
            end
          )
        end
      )
    end

    @tag spec: ["mutagen.test_selection.r3", "mutagen.cli.r20"]
    test "honors custom-path tags and runs the cleanup once", %{archive: host} do
      assert_host_run(host, "tag:pricing")
    end

    @tag spec: ["mutagen.coverage.r11", "mutagen.cli.r20", "mutagen.json_schema.r14"]
    test "all-excluded coverage aborts and runs cleanup once", %{archive: host} do
      trace = Path.join(host.dir, "runs.log")
      File.write!(trace, "")
      helper = File.read!(Path.join(host.dir, "checks/test_helper.exs"))

      with_file(
        host,
        "checks/test_helper.exs",
        helper <> "\nExUnit.configure(include: [])\n",
        fn ->
          {stdout, status} = mutate(host, ["--stream"])
          assert status != 0

          assert %{
                   "abort_reason" => "no_tests_run",
                   "mutation" => :null,
                   "warnings" => [],
                   "details" => %{"excluded" => 3, "include" => [], "exclude" => exclude}
                 } = decode_report(stdout)

          assert "pricing" in exclude
          assert File.read!(trace) == "helper\ncleanup\n"
        end
      )
    end

    @tag spec: "mutagen.mutation_pipeline.r22"
    test "a timed-out mutant releases the shared Sandbox before the next site", %{archive: host} do
      original_scope = File.read!(Path.join(host.dir, @scope))

      scope =
        String.replace(
          original_scope,
          "  def price",
          """
            def settle(id) do
              order = Repo.get!(Order, id)

              if order.quantity > 0 do
                :settled
              else
                Process.sleep(:infinity)
              end
            end

            def price
          """
          |> String.trim_trailing()
        )

      original_tests = File.read!(Path.join(host.dir, @tests))

      tests =
        original_tests
        |> String.replace("DataCase, async: true", "DataCase, async: false")
        |> String.replace(
          "actual = Orders.price",
          "assert Orders.settle(order.id) == :settled\n    actual = Orders.price"
        )

      with_file(host, @scope, scope, fn ->
        with_file(host, @tests, tests, fn ->
          {stdout, status} = mutate(host, ["--timeout-ms", "1500"])
          assert status == 0
          results = decode_report(stdout)["mutation"]["results"]

          timed_out = Enum.find_index(results, &(&1["status"] == "timeout"))

          survived =
            Enum.find_index(
              results,
              &(&1["mutator"] == "else_removal" and
                  &1["before"] =~ "total >= 10" and &1["status"] == "survived")
            )

          assert is_integer(timed_out) and is_integer(survived) and timed_out < survived
        end)
      end)
    end

    @tag spec: ["mutagen.cli.r19", "mutagen.json_schema.r17"]
    test "redacts the password from Ecto.InvalidURLError", %{archive: host} do
      with_file(
        host,
        "checks/test_helper.exs",
        """
        raise Ecto.InvalidURLError, url: "ecto://fixture:fixture-db-secret@db.invalid", message: "missing database"
        """,
        fn ->
          {stdout, status} = mutate(host, ["--include-host-output"])
          assert status == 2
          assert abort_message(stdout, "test_helper_load_failed") =~ "[REDACTED]"
          refute stdout =~ "fixture-db-secret"
        end
      )
    end

    @tag spec: "mutagen.cli.r14"
    test "skipping the host app still loads the helper", %{archive: host} do
      with_file(
        host,
        "checks/test_helper.exs",
        """
        if Process.whereis(HostSetupFixture.Repo), do: raise("unexpected running repo")
        true = Application.fetch_env!(:host_setup_fixture, :runtime_config_loaded)
        raise "helper ran without the repo"
        """,
        fn ->
          assert abort(host, "test_helper_load_failed", ["--no-host-app"]) ==
                   "helper ran without the repo"

          assert abort(put_env(host, "MUTAGEN_NO_HOST_APP", "1"), "test_helper_load_failed") ==
                   "helper ran without the repo"
        end
      )
    end
  end

  @tag spec: ["mutagen.cli.r26", "mutagen.json_schema.r19", "mutagen.json_schema.r22"]
  test "default artifacts keep host canaries out and ordinary host I/O off stdout", %{
    archive: host
  } do
    canary = "ZZHostCanaryOnlyInEnvironment"

    host =
      host
      |> put_env("FIXTURE_REPORT_CANARY", canary)
      |> put_env("DATABASE_URL", "ecto://:#{canary}@fake.invalid/db")

    helper = "checks/test_helper.exs"
    original_helper = File.read!(Path.join(host.dir, helper))

    tests =
      host.dir
      |> Path.join(@tests)
      |> File.read!()
      |> String.replace(
        ~s|test "prices an order above the surcharge threshold"|,
        ~S|test "generated #{System.fetch_env!("FIXTURE_REPORT_CANARY")} case"|
      )

    tests =
      String.replace(
        tests,
        "    actual = Orders.price",
        """
            require Logger
            value = System.fetch_env!("FIXTURE_REPORT_CANARY")
            assert :ok = GenServer.call(HostSetupFixture.Output, {:write, value})
            Logger.debug("fixture log " <> value)
            Repo.query!("SELECT $1::text", [value])
            IO.write(:stderr, "fixture diagnostic token: " <> value <> "\\n")
            if File.exists?("fail-fixture"), do: raise("test failed with " <> value)
            actual = Orders.price
        """
        |> String.trim_trailing()
      )

    with_file(host, @tests, tests, fn ->
      {stdout, 0} = mutate(host, [])
      assert decode_report(stdout)["aborted"] == false
      assert {repeated, 0} = mutate(host, [])
      assert without_timings(stdout) == without_timings(repeated)
      refute stdout =~ canary

      assert {"", 0} = mutate(host, ["--no-source", "--stream", "--json", "safety.ndjson"])
      lines = read_stream_report(host, "safety.ndjson", canary)
      assert List.last(lines)["aborted"] == false
      assert stream_results = Enum.filter(lines, &(&1["kind"] == "result"))
      assert stream_results != []

      for result <- stream_results,
          do: assert(Map.take(result, ~w(before before_source after file function)) == %{})

      {opted_in, 0} = mutate(host, ["--include-host-output"])
      refute opted_in =~ canary
      assert opted_in =~ "fixture diagnostic token: [REDACTED]"
      refute opted_in =~ "fixture log"
      refute opted_in =~ "SELECT $1"
      refute opted_in =~ "redefining module"

      failure = Path.join(host.dir, "fail-fixture")
      File.touch!(failure)

      try do
        assert {"", 2} = mutate(host, ["--stream", "--json", "safety.ndjson"])
        report = host |> read_stream_report("safety.ndjson", canary) |> List.last()
        assert report["abort_reason"] == "baseline_red"

        assert report["baseline"]["failures"] == [
                 %{"module" => "HostSetupFixture.OrdersTest", "count" => 1}
               ]

        assert report["details"]["failures"] == report["baseline"]["failures"]

        {opted_in, 2} = mutate(host, ["--include-host-output"])
        assert [%{"name" => name}] = decode_report(opted_in)["baseline"]["failures"]
        assert name =~ canary
        refute Map.has_key?(report["details"], "message")
      after
        File.rm!(failure)
      end
    end)

    filters = ~S"""

    value = System.fetch_env!("FIXTURE_REPORT_CANARY")
    exclude = [String.to_atom("tag_" <> value), region: {:tenant, value}, note: value]
    ExUnit.configure(
      exclude: ExUnit.configuration()[:exclude] ++ exclude,
      include: ExUnit.configuration()[:include] ++ [audience: value]
    )
    """

    with_file(host, helper, original_helper <> filters, fn ->
      assert {"", 0} = mutate(host, ["--stream", "--json", "safety.ndjson"])
      report = host |> read_stream_report("safety.ndjson", canary) |> List.last()
      assert Enum.all?(~w(region note) ++ ["host tag"], &(&1 in report["tests"]["exclude"]))
      assert "audience" in report["tests"]["include"]

      with_file(
        host,
        helper,
        original_helper <>
          filters <>
          "\nExUnit.configure(include: [audience: value], exclude: [:pricing | ExUnit.configuration()[:exclude]])",
        fn ->
          assert {"", 2} = mutate(host, ["--stream", "--json", "safety.ndjson"])
          [report] = read_stream_report(host, "safety.ndjson", canary)
          assert report["abort_reason"] == "no_tests_run"
          assert "region" in report["details"]["exclude"]
          assert "audience" in report["details"]["include"]
        end
      )
    end)

    for {source, field, expected} <- [
          {~S|throw(String.to_atom("throw_" <> System.fetch_env!("FIXTURE_REPORT_CANARY")))|,
           "reason", "host_reason"},
          {~S|exit(String.to_atom("exit_" <> System.fetch_env!("FIXTURE_REPORT_CANARY")))|,
           "reason", "host_reason"},
          {~S"""
           module = Module.concat(HostSetupFixture, System.fetch_env!("FIXTURE_REPORT_CANARY"))
           Module.create(module, quote(do: defexception(message: "fixture")), Macro.Env.location(__ENV__))
           raise module
           """, "exception", "host exception"}
        ] do
      with_file(host, helper, source, fn ->
        assert {"", 2} = mutate(host, ["--stream", "--json", "safety.ndjson"])
        [report] = read_stream_report(host, "safety.ndjson", canary)
        assert report["abort_reason"] == "test_helper_load_failed"
        assert report["details"][field] == expected
      end)
    end

    assert_mutation_canary(host, canary, original_helper)

    with_file(
      host,
      helper,
      ~S|raise "connection failed: " <> System.fetch_env!("DATABASE_URL")|,
      fn ->
        assert {"", 2} = mutate(host, ["--stream", "--json", "safety.ndjson"])
        [report] = read_stream_report(host, "safety.ndjson", canary)

        assert %{
                 "abort_reason" => "test_helper_load_failed",
                 "details" => %{
                   "step" => "test_helper",
                   "exception" => "RuntimeError",
                   "file" => ^helper,
                   "line" => 1,
                   "hint" => hint
                 }
               } = report

        assert hint =~ "test helper"
        refute Map.has_key?(report["details"], "message")

        assert {opted_in, 2} = mutate(host, ["--include-host-output"])

        assert decode_report(opted_in)["details"]["message"] =~
                 "ecto://[REDACTED]@fake.invalid/db"

        refute opted_in =~ canary
      end
    )

    config = "config/runtime.exs"
    runtime_config = File.read!(Path.join(host.dir, config))

    with_file(
      host,
      config,
      runtime_config <>
        ~S|raise CompileError, file: System.fetch_env!("FIXTURE_REPORT_CANARY"), line: 77, description: "startup failed"|,
      fn ->
        assert {"", 2} = mutate(host, ["--stream", "--json", "safety.ndjson"])
        [report] = read_stream_report(host, "safety.ndjson", canary)

        assert %{
                 "abort_reason" => "host_app_start_failed",
                 "details" => %{
                   "step" => "runtime_config",
                   "exception" => "CompileError",
                   "file" => ^config,
                   "line" => 4
                 }
               } = report

        refute Map.has_key?(report["details"], "message")
      end
    )
  end

  defp assert_mutation_canary(host, canary, original_helper) do
    pricing = "lib/host_setup_fixture/pricing.ex"

    macro_code = ~S"""

    defmodule HostSetupFixture.CanaryMacro do
      defmacro keep_add({:+, _, _} = operation), do: operation

      defmacro keep_add(_operation) do
        name = Module.concat(HostSetupFixture, System.fetch_env!("FIXTURE_REPORT_CANARY"))
        unless Code.ensure_loaded?(name) do
          Module.create(name, quote(do: defexception(message: "fixture")), Macro.Env.location(__ENV__))
        end
        raise name
      end
    end
    """

    scope =
      host.dir
      |> Path.join(@scope)
      |> File.read!()
      |> String.replace(
        "  def price",
        ~S"""
          require HostSetupFixture.CanaryMacro

          def reap_probe(n) do
            if n > 0 do
              :ok
            else
              name = String.to_atom("host_" <> System.fetch_env!("FIXTURE_REPORT_CANARY"))
              if pid = Process.whereis(name), do: Process.exit(pid, :kill)
              Process.sleep(:infinity)
            end
          end

          def price
        """
        |> String.trim_trailing()
      )
      |> String.replace("total + 2", "HostSetupFixture.CanaryMacro.keep_add(total + 2)")

    tests =
      host.dir
      |> Path.join(@tests)
      |> File.read!()
      |> String.replace(
        "actual = Orders.price",
        "assert :ok = Orders.reap_probe(order.quantity)\n    actual = Orders.price"
      )

    helper =
      original_helper <>
        ~S"""

        name = String.to_atom("host_" <> System.fetch_env!("FIXTURE_REPORT_CANARY"))
        Process.register(spawn(fn -> Process.sleep(:infinity) end), name)
        """

    with_file(host, pricing, File.read!(Path.join(host.dir, pricing)) <> macro_code, fn ->
      with_file(host, @scope, scope, fn ->
        with_file(host, @tests, tests, fn ->
          with_file(host, "checks/test_helper.exs", helper, fn ->
            assert {"", 0} =
                     mutate(host, ["--stream", "--json", "safety.ndjson", "--timeout-ms", "1200"])

            lines = read_stream_report(host, "safety.ndjson", canary)
            assert "host_process_died: 1 registered process" in List.last(lines)["warnings"]

            assert Enum.any?(
                     lines,
                     &match?(%{"kind" => "compile_error", "exception" => "host exception"}, &1)
                   )
          end)
        end)
      end)
    end)
  end

  @tag spec: "mutagen.cli.r30"
  test "a helper cannot replace the loaded sanitizer", %{archive: host} do
    helper = "checks/test_helper.exs"

    shadow = """
    defmodule MutagenEx.JsonReporter.Sanitizer do
      def clean(value), do: value
    end
    ExUnit.start(autorun: false)
    """

    with_file(host, helper, shadow, fn ->
      assert {"", 2} = mutate(host, ["--json", "shadow.json"])
      report = host.dir |> Path.join("shadow.json") |> File.read!() |> decode_report()
      assert report["abort_reason"] == "runtime_load_failed"
      assert report["details"]["module"] == "MutagenEx.JsonReporter.Sanitizer"
    end)
  end

  @tag spec: "mutagen.cli.r25"
  test "invalid redact configuration aborts at startup in the chosen file", %{archive: host} do
    config = "config/runtime.exs"
    original = File.read!(Path.join(host.dir, config))

    for value <- ["[\"(\"]", "\"not a list\"", "[:wrong_element]"] do
      with_file(host, config, original <> "\nconfig :mutagen_ex, redact: #{value}\n", fn ->
        assert {"", 2} = mutate(host, ["--json", "safety.json", "--include-host-output"])
        report = host.dir |> Path.join("safety.json") |> File.read!() |> decode_report()
        assert report["abort_reason"] == "invalid_redact_config"
        assert report["details"]["step"] == "redact_config"
      end)
    end
  end

  @tag spec: "mutagen.cli.r26"
  test "cited test syntax errors honor --json", %{archive: host} do
    with_file(host, @tests, "defmodule Broken do", fn ->
      assert {"", 2} = mutate(host, ["--json", "syntax.json"])
      report = host.dir |> Path.join("syntax.json") |> File.read!() |> decode_report()
      assert report["abort_reason"] == "parse_error"
      assert report["details"]["file"] == @tests
    end)
  end

  @tag spec: "mutagen.cli.r27"
  test "coverage, baseline and after-suite callbacks have deadlines", %{archive: host} do
    tests =
      host.dir
      |> Path.join(@tests)
      |> File.read!()
      |> String.replace("@tag :pricing", "@tag :pricing\n  @tag timeout: :infinity")

    for {phase, operator} <- [{"coverage", "=="}, {"baseline", "!="}] do
      blocking =
        String.replace(
          tests,
          "    actual = Orders.price",
          """
              if :code.which(Orders) #{operator} :cover_compiled, do: Process.sleep(:infinity)
              actual = Orders.price
          """
          |> String.trim_trailing()
        )

      with_file(host, @tests, blocking, fn ->
        assert {stdout, 2} = mutate(host, ["--boot-timeout-ms", "5000", "--timeout-ms", "600"])
        report = decode_report(stdout)
        assert report["abort_reason"] == "#{phase}_timeout"
        assert report["details"]["limit"] == 6000
        assert report["details"]["hint"] =~ "--timeout-ms"
        assert report["details"]["hint"] =~ "--boot-timeout-ms"
      end)
    end

    helper = "checks/test_helper.exs"

    cleanup = ~S"""
    ExUnit.start(autorun: false)
    ExUnit.after_suite(fn _ ->
      report = :json.decode(File.read!("cleanup.json"))
      Process.sleep(1200)
      File.write!("cleanup-observed", report["abort_reason"] |> inspect())
    end)
    """

    original = File.read!(Path.join(host.dir, helper))
    observed = Path.join(host.dir, "cleanup-observed")

    with_file(host, helper, cleanup <> original, fn ->
      assert {"", 0} = mutate(host, ["--json", "cleanup.json", "--boot-timeout-ms", "5000"])
      assert File.read!(observed) == ":null"
    end)

    File.rm!(observed)

    with_file(host, helper, cleanup <> "\nProcess.sleep(:infinity)", fn ->
      assert {"", 2} = mutate(host, ["--json", "cleanup.json", "--boot-timeout-ms", "5000"])
      report = host.dir |> Path.join("cleanup.json") |> File.read!() |> decode_report()
      assert report["abort_reason"] == "host_setup_timeout"
      assert report["details"]["step"] == "test_helper"
      assert File.read!(observed) == inspect("host_setup_timeout")
    end)
  end

  @tag spec: ["mutagen.cli.r6", "mutagen.cli.r20"]
  test "a host after-suite halt uses its own exit code after writing the report", %{archive: host} do
    helper = "checks/test_helper.exs"
    original = File.read!(Path.join(host.dir, helper))
    halt = "ExUnit.after_suite(fn _ -> System.halt(7) end)\n"

    with_file(host, helper, halt <> original, fn ->
      assert {"", 7} = mutate(host, ["--json", "halt.json"])

      assert %{"aborted" => false, "mutation" => %{"total" => total}} =
               host.dir |> Path.join("halt.json") |> File.read!() |> decode_report()

      assert total > 0
    end)
  end

  defp read_stream_report(host, path, canary) do
    data = File.read!(Path.join(host.dir, path))
    refute data =~ canary
    data |> String.split("\n", trim: true) |> Enum.map(&decode_report/1)
  end

  defp prepare_host(opts) do
    suffix = Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
    dir = Path.join(@project_root, "tmp/host_setup_#{suffix}")
    database = System.get_env("HOST_SETUP_DB_NAME", "mutagen_host_setup") <> "_" <> suffix <> "_"
    File.mkdir_p!(Path.dirname(dir))
    File.cp_r!(@fixture, dir)

    host = %{
      dir: dir,
      env: [
        {"MIX_ENV", "test"},
        {"MIX_TARGET", nil},
        {"MIX_QUIET", if(opts[:mutagen_path], do: "1")},
        {"MIX_ARCHIVES", Path.join(dir, "archives")},
        {"MIX_TEST_PARTITION", opts[:partition]},
        {"HOST_SETUP_MUTAGEN_PATH", opts[:mutagen_path]},
        {"HOST_SETUP_DB_NAME", database},
        {"MUTAGEN_NO_HOST_APP", nil}
      ]
    }

    on_exit(fn -> File.rm_rf!(dir) end)
    mix!(host, ["deps.get"])

    on_exit(fn -> mix!(host, ["ecto.drop", "--quiet"]) end)

    host
  end

  defp assert_host_run(host, tests \\ @tests) do
    trace = Path.join(host.dir, "runs.log")
    File.write!(trace, "")
    {stdout, status} = mutate(host, [], tests)
    assert status == 0, "mix mutagen exited #{status}\n#{stdout}"

    report = decode_report(stdout)

    assert %{
             "aborted" => false,
             "meta" => %{"tool_version" => version},
             "baseline" => %{"passed" => 1, "failed" => 0}
           } = report

    assert version == MutagenEx.MixProject.project()[:version]

    results = report["mutation"]["results"]
    assert %{"killed" => 3, "survived" => 1, "total" => 4} = report["mutation"]
    assert Enum.any?(results, &match?(%{"before" => "total + 2", "status" => "killed"}, &1))
    assert Enum.any?(results, &match?(%{"mutator" => "else_removal", "status" => "survived"}, &1))

    assert File.read!(trace) ==
             "helper\n" <> String.duplicate("order\n", 2 + length(results)) <> "cleanup\n"
  end

  defp mutate(host, args, tests \\ @tests) do
    mix(host, ["mutagen", "--scope", @scope, "--tests", tests] ++ args)
  end

  defp abort(host, reason, args \\ []) do
    {stdout, status} = mutate(host, args ++ ["--include-host-output"])
    assert status == 2
    abort_message(stdout, reason)
  end

  defp abort_message(json, reason) do
    assert %{
             "aborted" => true,
             "abort_reason" => ^reason,
             "details" => %{"message" => message},
             "baseline" => :null,
             "mutation" => :null
           } = decode_report(json)

    message
  end

  defp decode_report(stdout) do
    :json.decode(stdout)
  rescue
    _ -> flunk("expected one JSON document, got:\n#{stdout}")
  end

  defp without_timings(stdout) do
    report = decode_report(stdout)
    assert %{"meta" => %{"timings_ms" => %{}}} = report

    normalized =
      Regex.replace(~r/"timings_ms":\{[^{}]+\},|,"timings_ms":\{[^{}]+\}(?=\})/, stdout, "")

    assert decode_report(normalized) == update_in(report["meta"], &Map.delete(&1, "timings_ms"))
    normalized
  end

  defp put_env(host, name, value) do
    %{host | env: List.keystore(host.env, name, 0, {name, value})}
  end

  defp with_file(host, file, replacement, fun) do
    path = Path.join(host.dir, file)
    original = File.read!(path)

    try do
      if replacement, do: File.write!(path, replacement), else: File.rm!(path)
      fun.()
    after
      File.write!(path, original)
    end
  end

  defp mix!(host, args) do
    {output, status} = mix(host, args, stderr_to_stdout: true)
    assert status == 0, "mix #{Enum.join(args, " ")} exited #{status}\n#{output}"
    output
  end

  defp mix(host, args, opts \\ []) do
    System.cmd("mix", args, [cd: host.dir, env: host.env] ++ opts)
  end
end
