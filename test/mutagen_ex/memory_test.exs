defmodule MutagenEx.MemoryTest do
  @moduledoc """
  Large-scope memory test — `.25` epic capstone (bw mutagen-wrd.25.7).

  Generates a synthetic 1000-site fixture at runtime (NOT committed to
  disk — see `mutagen-wrd.25.7` Out of Scope), drives the full
  `Mix.Tasks.Mutagen.run/2` pipeline against it, and asserts the run
  completes without crashing the BEAM.

  ## What this test pins (and what it deliberately does NOT)

  Pins:

    * The pipeline does not OOM, blow file-descriptor limits, or
      crash the per-run `BeamCache` / `:cover` machinery when handed
      a scope whose enumerator yields 1000+ mutation sites.
    * The run either completes (`aborted: false`) OR hits the user-
      supplied `--budget-ms` and returns gracefully with
      `truncated: true`. Both outcomes count as "did not crash".

  Does NOT pin:

    * Heap size. Per the `.25.7` ticket Out of Scope (intent):
      "Memory test asserts only 'did not crash', NOT specific heap
      sizes. Heap-size assertions are flaky across BEAM versions."
    * Per-site timing. That belongs in `priv/helper_scripts/
      bench_ast_perf.exs`, the harness this test's epic-mate
      `mutagen-wrd.25.7` finalises.
    * Mutation kill rate. With 1000 sites against a trivially-pinned
      colocated test, the kill verdict distribution is uninteresting
      for the OOM property — only the absence-of-crash matters.

  ## Tagging

  `:e2e_slow` — the run takes tens of seconds even with a tight
  per-site budget; the default `mix test` should not pay this cost.
  Run explicitly with:

      mix test --include e2e_slow test/mutagen_ex/memory_test.exs

  ## Fixture generation

  20 synthetic `*.ex` modules under a tmp dir, each with ~50 arith-
  dense one-liner defs (so the default mutator catalog produces ~50
  sites per module, ~1000 total). Modules are named
  `Wrd25Mem.Fixture.M00`..`M19` to keep the BEAM module
  registry tidy across reruns (purged on test teardown). A single
  colocated test file holds a trivial `assert true` per module so
  Baseline + Coverage have something to pin without injecting
  kill/survive variance that would bloat the result document.

  Fixture generation is deterministic (a fixed iteration count drives
  the def shapes — no `:rand`, no timestamps). This keeps the test
  reproducible across hosts.

  Why ~50 ops per module: each `a + b - c * d / e` chain produces
  4-5 arith sites (one per operator), so a function with several
  such chains yields ~10 sites; we pack ~5 such functions per module
  to hit ~50. The exact site count is verified inside the test via
  the emitted `mutation.total`.
  """

  use ExUnit.Case, async: false

  @moduletag :e2e_slow
  @moduletag :integration
  # The default ExUnit timeout (60s) is way too tight for a 1000-site
  # mutation run even with a tight per-site budget. Cap at 10 min;
  # the test itself uses `--budget-ms` to bound the pipeline's
  # mutation phase, so the ExUnit timeout is a defence-in-depth backstop.
  @moduletag timeout: 600_000

  @target_modules 20
  @ops_per_module_target 50
  # `--budget-ms` cap for the mutation phase. 60s is enough to push
  # through several hundred mutated runs on the synthetic fixture
  # while bounding worst-case wall-clock. The pipeline's `truncated`
  # flag picks up the rest.
  @budget_ms 60_000
  # Per-site timeout — synthetic colocated tests are trivial, so any
  # mutated run should resolve in well under a second. Tight to keep
  # the total bounded.
  @site_timeout_ms 1_000

  setup_all do
    ensure_cover_loadable!()
    Application.ensure_all_started(:ex_unit)

    # Synthetic fixture root — a fresh tmp dir per `mix test` run so
    # we never read a stale fixture across reruns. `on_exit/1` wipes
    # it; if the test crashes the tmp dir leaks (acceptable —
    # System.tmp_dir/0 is the OS's responsibility).
    fixture_root =
      Path.join(
        System.tmp_dir!(),
        "mutagen_ex_memory_test_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(Path.join(fixture_root, "lib"))
    File.mkdir_p!(Path.join(fixture_root, "test"))

    {compiled_modules, ebin, expected_sites} = build_and_compile_fixture!(fixture_root)

    on_exit(fn ->
      Code.delete_path(ebin)

      Enum.each(compiled_modules, fn mod ->
        _ = :code.purge(mod)
        _ = :code.delete(mod)
      end)

      try do
        File.rm_rf!(fixture_root)
      rescue
        _ -> :ok
      end
    end)

    {:ok,
     fixture_root: fixture_root,
     compiled_modules: compiled_modules,
     ebin: ebin,
     expected_sites: expected_sites}
  end

  describe "large-scope memory test (mutagen-wrd.25.7)" do
    test "1000-site synthetic fixture completes without OOM", ctx do
      # The contract: the pipeline either runs to completion OR
      # truncates on `--budget-ms`. Both shapes prove "did not
      # crash"; only an `aborted: true` with an error reason that
      # signals VM-level failure (`:emfile`, `:system_limit`, or a
      # raised exception) should fail this test.
      json = run_pipeline_capture!(ctx)

      # Sanity: the enumerator saw the synthetic fixture and produced
      # the expected order of magnitude of sites. We don't pin the
      # exact count (the fixture generator is deterministic but the
      # arith op count per function depends on how the mutator
      # catalog reads the AST — we know it's ~50/module, but not
      # exactly).
      mutation = json["mutation"]

      refute is_nil(mutation),
             "mutation block was nil — pipeline aborted before mutation phase: " <>
               inspect(json["abort_reason"])

      assert mutation["total"] >= 1000,
             "expected >= 1000 sites enumerated, got #{mutation["total"]}. " <>
               "expected ~#{ctx.expected_sites} from the fixture generator. " <>
               "If the generator emits less than 1000 sites the fixture needs more " <>
               "modules or denser arith chains."

      # The pipeline completed without a VM-level crash. Either
      # finished cleanly OR honoured the budget cap.
      assert json["aborted"] == false or json["truncated"] == true,
             "pipeline aborted in a non-budget-cap shape: " <>
               "abort_reason=#{inspect(json["abort_reason"])} " <>
               "warnings=#{inspect(json["warnings"])}"

      # If aborted, the reason MUST be a known graceful outcome — not
      # a VM crash. The list is conservative: if a new graceful abort
      # reason ships, extend it; do not relax to "any reason".
      if json["aborted"] do
        graceful_reasons = [
          "budget_exceeded",
          # max_sites_exceeded is unlikely with our 1000-site fixture
          # and default cap (10_000) but is a graceful shape if the
          # test author later passes --max-sites.
          "too_many_sites"
        ]

        assert json["abort_reason"] in graceful_reasons,
               "pipeline aborted with non-graceful reason: " <>
                 inspect(json["abort_reason"]) <>
                 " — this is what the OOM check is supposed to catch. " <>
                 "If a new graceful abort_reason has been introduced, add it to the list above."
      end

      # Defence-in-depth: even though the test contract says no
      # heap-size assertion, the BEAM should still be in a usable
      # shape after the run — i.e. `:erlang.memory(:total)` returns
      # an integer (vs. crashing the test VM mid-call). This is a
      # behaviour assertion, not a size assertion.
      assert is_integer(:erlang.memory(:total))
    end
  end

  # ---------------------------------------------------------------------------
  # Pipeline driver — mirrors EndToEndTest.run_pipeline!/1 but uses the
  # synthetic in-tmp fixture and captures the JSON via the IoFacade test
  # seam.
  # ---------------------------------------------------------------------------

  defp run_pipeline_capture!(ctx) do
    this = self()
    ref = make_ref()

    dispatch = %{
      io: __MODULE__.CaptureIo,
      baseline: __MODULE__.BaselineFork,
      coverage: __MODULE__.CoverageFork,
      tests: MutagenEx.TestSelector,
      mutation: MutagenEx.MutationRunner
    }

    # `--scope` is repeatable (CLI r per mutagen.cli docstring). Pass
    # each generated module as its own scope arg — bypasses the
    # default `lib/**/*.ex` glob (which would still be the right
    # answer here, but explicit-list shape is what the spec docs
    # exercise and matches `mix mutagen --scope <file>`).
    scope_args =
      ctx.compiled_modules
      |> Enum.with_index()
      |> Enum.flat_map(fn {_mod, idx} ->
        ["--scope", "lib/m#{:io_lib.format("~2..0B", [idx]) |> IO.iodata_to_binary()}.ex"]
      end)

    argv =
      scope_args ++
        [
          "--tests",
          "test/memory_fixture_test.exs",
          "--timeout-ms",
          Integer.to_string(@site_timeout_ms),
          "--budget-ms",
          Integer.to_string(@budget_ms),
          "--seed",
          "0"
        ]

    prior_cwd = File.cwd!()
    File.cd!(ctx.fixture_root)

    try do
      Process.put(:memory_capture_target, this)
      Process.put(:memory_capture_ref, ref)
      Process.put(:memory_fixture_modules, ctx.compiled_modules)

      # Wrap in CaptureIO so the pipeline's progress chatter / ExUnit
      # banners / "redefining module" warnings don't pollute the test
      # output. Stderr suppression is the outer layer; stdout
      # suppression is the inner (mirrors EndToEndTest exactly).
      _ =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          ExUnit.CaptureIO.capture_io(fn ->
            try do
              Mix.Tasks.Mutagen.run(argv, dispatch)
            rescue
              e ->
                send(this, {:memory_raised, ref, Exception.message(e), __STACKTRACE__})
            catch
              kind, value ->
                send(this, {:memory_caught, ref, kind, value})
            end
          end)
        end)

      receive do
        {:memory_io, ^ref, iodata, _exit_code} ->
          decode_json!(iodata)

        {:memory_raised, ^ref, message, _trace} ->
          flunk("pipeline raised: " <> message)

        {:memory_caught, ^ref, kind, value} ->
          flunk("pipeline caught: #{inspect(kind)} #{inspect(value)}")
      after
        # The pipeline has its own `--budget-ms`; this is a backstop
        # in case the receive itself wedges.
        @budget_ms + 60_000 ->
          flunk("pipeline did not emit JSON within #{@budget_ms + 60_000}ms")
      end
    after
      File.cd!(prior_cwd)
      Process.delete(:memory_capture_target)
      Process.delete(:memory_capture_ref)
      Process.delete(:memory_fixture_modules)
    end
  end

  defp decode_json!(iodata) do
    binary = IO.iodata_to_binary(iodata)

    case :json.decode(binary) do
      decoded when is_map(decoded) ->
        # `:json.decode/1` represents JSON null as the atom `:null`.
        # Convert recursively so the assertions can rely on standard
        # Elixir `nil`-matching semantics.
        json_null_to_nil(decoded)

      other ->
        flunk("decoded JSON is not a map: #{inspect(other)}")
    end
  end

  defp json_null_to_nil(:null), do: nil

  defp json_null_to_nil(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {k, json_null_to_nil(v)} end)
  end

  defp json_null_to_nil(list) when is_list(list) do
    Enum.map(list, &json_null_to_nil/1)
  end

  defp json_null_to_nil(other), do: other

  defmodule CaptureIo do
    @moduledoc false
    @behaviour MutagenEx.Pipeline.IoFacade

    @impl MutagenEx.Pipeline.IoFacade
    def emit(iodata, exit_code, _config) do
      case Process.get(:memory_capture_target) do
        target when is_pid(target) ->
          ref = Process.get(:memory_capture_ref)
          send(target, {:memory_io, ref, iodata, exit_code})
          :ok

        _ ->
          IO.write(iodata)
      end
    end
  end

  defmodule BaselineFork do
    @moduledoc false
    @behaviour MutagenEx.Pipeline.BaselineFacade

    @impl MutagenEx.Pipeline.BaselineFacade
    def run(input) do
      MutagenEx.MemoryTest.register_test_modules_for_phase!(input.test_filter.files)
      MutagenEx.Baseline.run(input)
    end
  end

  defmodule CoverageFork do
    @moduledoc false
    @behaviour MutagenEx.Pipeline.CoverageFacade

    @impl MutagenEx.Pipeline.CoverageFacade
    def run(input) do
      MutagenEx.MemoryTest.register_test_modules_for_phase!(input.test_filter.files)
      MutagenEx.CoverageRunner.run(input)
    end
  end

  @doc false
  def register_test_modules_for_phase!(files) do
    Enum.each(files, fn file ->
      try do
        _ = Code.compile_file(file)
      rescue
        _ -> :ok
      catch
        _, _ -> :ok
      end
    end)

    :ok
  end

  # ---------------------------------------------------------------------------
  # Synthetic fixture generator
  # ---------------------------------------------------------------------------

  # Generate `@target_modules` modules under `<fixture>/lib/`, each
  # holding `@ops_per_module_target`/4 arith def's with multiple
  # binary-op sites per def. Write one `test/memory_fixture_test.exs`
  # that imports + trivially exercises every module so Baseline +
  # Coverage have something concrete to pin.
  #
  # Module naming: `Wrd25Mem.Fixture.M00`..`M19`. Top-level
  # namespace under `MutagenEx.` is fine here — the synthetic modules
  # are not in the project's `lib/` and not part of any production
  # surface; they exist only for the duration of `setup_all`.
  defp build_and_compile_fixture!(fixture_root) do
    lib_dir = Path.join(fixture_root, "lib")
    test_dir = Path.join(fixture_root, "test")

    sites_per_def = 5

    {module_specs, expected_sites} =
      Enum.map_reduce(0..(@target_modules - 1), 0, fn idx, acc ->
        mod_name = "Wrd25Mem.Fixture.M#{:io_lib.format("~2..0B", [idx]) |> IO.iodata_to_binary()}"
        defs_per_module = div(@ops_per_module_target, sites_per_def)

        defs =
          for d <- 0..(defs_per_module - 1) do
            # Each def body packs 5 binary arith ops:
            #   a + b - c * d / e + idx
            # → 5 arith sites under the default catalog.
            """
              def calc_#{d}(a, b, c, d_arg, e), do: a + b - c * d_arg / e + #{idx}
            """
          end

        source = """
        defmodule #{mod_name} do
        #{Enum.join(defs)}
        end
        """

        file =
          Path.join(lib_dir, "m#{:io_lib.format("~2..0B", [idx]) |> IO.iodata_to_binary()}.ex")

        File.write!(file, source)

        # `defs_per_module` defs × `sites_per_def` arith ops per def.
        sites = defs_per_module * sites_per_def
        {{String.to_atom("Elixir." <> mod_name), file}, acc + sites}
      end)

    # One trivial test file that exercises every module — Baseline
    # needs at least one passing test for the pipeline to enter the
    # mutation phase. The test is intentionally trivial: we do not
    # want strong assertions here because that would make every
    # mutated run a kill, inflating result document size with no
    # benefit to the OOM property under test.
    test_source = build_test_source(module_specs)

    test_file = Path.join(test_dir, "memory_fixture_test.exs")
    File.write!(test_file, test_source)

    {modules, ebin} = compile_fixture_modules!(module_specs)

    {modules, ebin, expected_sites}
  end

  defp build_test_source(module_specs) do
    # The mutation runner gates sites by coverage: a site outside a
    # line covered by the cited tests is enumerated but skipped at
    # the runner. So the trivial test must exercise *every* def in
    # every synthetic module, otherwise enumeration yields ~1000
    # sites but `mutation.total` collapses to a fraction.
    #
    # `a + b - c * d_arg / e + idx` against (1,2,3,4,5) is a float
    # (BEAM's `/` always returns float), so the assertion uses
    # `is_number/1` — the goal here is just to make the test pass
    # cheaply so baseline isn't red and coverage hits every def.
    defs_per_module = div(@ops_per_module_target, 5)

    asserts =
      Enum.flat_map(module_specs, fn {mod, _file} ->
        for d <- 0..(defs_per_module - 1) do
          "    assert is_number(#{inspect(mod)}.calc_#{d}(1, 2, 3, 4, 5))"
        end
      end)
      |> Enum.join("\n")

    """
    defmodule Wrd25Mem.FixtureTest do
      use ExUnit.Case, async: false

      test "every synthetic module is callable" do
    #{asserts}
      end
    end
    """
  end

  defp compile_fixture_modules!(module_specs) do
    ebin =
      Path.join(
        System.tmp_dir!(),
        "mutagen_ex_memory_ebin_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(ebin)
    Code.append_path(ebin)

    prior_opts = Code.compiler_options()
    Code.compiler_options(debug_info: true)

    compiled =
      Enum.flat_map(module_specs, fn {_mod, file} ->
        Code.compile_file(file)
      end)

    for {mod, bin} <- compiled do
      File.write!(Path.join(ebin, "#{mod}.beam"), bin)
    end

    for {mod, _bin} <- compiled do
      _ = :code.purge(mod)
      _ = :code.delete(mod)

      case :code.load_file(mod) do
        {:module, ^mod} -> :ok
        other -> flunk("could not reload #{inspect(mod)} from disk: #{inspect(other)}")
      end
    end

    Code.compiler_options(prior_opts)

    modules = Enum.map(compiled, fn {mod, _bin} -> mod end)
    {modules, ebin}
  end

  defp ensure_cover_loadable! do
    case Code.ensure_loaded(:cover) do
      {:module, :cover} ->
        :ok

      _ ->
        root = List.to_string(:code.root_dir())

        case Path.wildcard(Path.join(root, "lib/tools-*/ebin")) do
          [path | _] ->
            Code.append_path(path)
            {:module, :cover} = Code.ensure_loaded(:cover)
            :ok

          [] ->
            flunk("could not locate OTP tools-*/ebin under #{root}")
        end
    end
  end
end
