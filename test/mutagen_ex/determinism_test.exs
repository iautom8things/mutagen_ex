defmodule MutagenEx.DeterminismTest do
  @moduledoc """
  Determinism safety-net — bw mutagen-wrd.25.1 (S0) re-targeted to the
  wrd25 fixture in bw mutagen-wrd.25.2 (S1).

  This is the safety-net test that anchors the wrd25 refactor epic.
  It pins the property the whole epic must preserve: **two
  consecutive invocations of the `mix mutagen` pipeline against the
  same input produce byte-identical JSON output**. See
  `mutagen.decision.serial_execution_and_seed` and
  `mutagen.mutation_pipeline.r15` for the determinism contract.

  ## Why this lives here, not in EndToEndTest

  `EndToEndTest` checks pipeline correctness against goldens that
  normalise per-host fields (elixir/otp version, cover-warning paths,
  bitmap byte counts) so the goldens hold across machines. This test
  asserts a stronger and orthogonal property: same host, same
  process, same inputs → byte-identical OUTPUT. No normalisation —
  any drift between the two runs is the determinism contract
  breaking.

  ## What this test does

  1. Compiles the wrd25 fixture's `arith_dense.ex` into a tmp ebin
     (cover's `compile_beam/1` precondition) and reloads from disk —
     same setup `EndToEndTest` uses.
  2. Runs `Mix.Tasks.Mutagen.run/2` against
     `lib/arith_dense.ex` with `--seed 0` and `--timeout-ms 2000`.
     Captures the emitted JSON iodata.
  3. Resets per-scenario state (`:cover.stop`, beam reload,
     `Code.compile_file` of the cited test file).
  4. Runs the same invocation again, captures iodata.
  5. Asserts the two raw iodata blobs are byte-identical via
     `IO.iodata_to_binary/1` compare.

  ## Targeting

  Targets the wrd25 200-site bench fixture at
  `priv/helper_scripts/bench_fixtures/wrd25_200sites/`. Specifically
  scopes to one of the fixture's dense modules
  (`lib/arith_dense.ex`) — that's enough surface area to flush out
  ordering drift in the helper-lift / sorted-wildcard paths without
  pushing the e2e_slow runtime past its budget. The contract being
  tested does not change with the retarget — only the input.

  ## Tagging

  `:e2e_slow` so it stays out of the default `mix test` run; the
  full pipeline takes seconds and we don't need it on every keystroke.
  Run explicitly with:

      mix test --include e2e_slow test/mutagen_ex/determinism_test.exs
  """

  use ExUnit.Case, async: false

  @moduletag :e2e_slow
  @moduletag :integration
  @moduletag timeout: 600_000

  @lane_project_dir Path.expand(
                      "../../priv/helper_scripts/bench_fixtures/wrd25_200sites",
                      __DIR__
                    )
  @lane_lib_dir Path.join(@lane_project_dir, "lib")

  # The wrd25 fixture is a Mix project (priv/helper_scripts/.../mix.exs);
  # we only need to compile the file we're going to scope to, plus the
  # ones its tests refer to. Keep the list short — the determinism
  # test should be fast.
  @lane_fixture_files [
    "arith_dense.ex"
  ]

  setup_all do
    ensure_cover_loadable!()

    ebin =
      Path.join(
        System.tmp_dir!(),
        "mutagen_ex_determinism_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(ebin)
    Code.append_path(ebin)

    prior_opts = Code.compiler_options()
    Code.compiler_options(debug_info: true)

    {modules, _pre_md5} =
      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        Process.put(:determinism_compile_result, compile_lane_fixture(ebin))
      end)
      |> then(fn _ -> Process.get(:determinism_compile_result) end)

    Code.compiler_options(prior_opts)

    on_exit(fn ->
      Code.delete_path(ebin)
      File.rm_rf!(ebin)
      Process.delete(:determinism_compile_result)
    end)

    {:ok, ebin: ebin, compiled_modules: modules}
  end

  describe "deterministic JSON output across consecutive runs (mutagen.r2 contract)" do
    test "two runs of mix mutagen against arith_dense.ex produce byte-identical iodata", ctx do
      argv = [
        "--scope",
        "lib/arith_dense.ex",
        "--tests",
        "test/arith_dense_test.exs",
        "--timeout-ms",
        "2000",
        "--seed",
        "0"
      ]

      reset_pipeline_state!(ctx)
      bin1 = run_capture!(argv)

      reset_pipeline_state!(ctx)
      bin2 = run_capture!(argv)

      # The contract: byte-for-byte identical output. No normalisation
      # — any drift between the two runs is the determinism property
      # breaking, which is what this test exists to catch before the
      # wrd25 refactor.
      assert bin1 == bin2, """
      mutagen pipeline output differed between two consecutive runs against
      the same input. This breaks the determinism contract documented in
      mutagen.decision.serial_execution_and_seed and
      mutagen.mutation_pipeline.r15.

      First-run byte size:  #{byte_size(bin1)}
      Second-run byte size: #{byte_size(bin2)}

      Diff window around first difference:
      #{first_diff_window(bin1, bin2)}
      """
    end
  end

  # ---------------------------------------------------------------------------
  # Pipeline harness — mirrors EndToEndTest's `run_pipeline!/1` shape but
  # captures raw iodata (no JSON decode) and is deliberately kept
  # self-contained.
  # ---------------------------------------------------------------------------

  defp run_capture!(argv) do
    this = self()
    ref = make_ref()

    dispatch = %{
      io: __MODULE__.CaptureIoCollaborator,
      tests: MutagenEx.TestSelector,
      baseline: __MODULE__.BaselineCollaborator,
      coverage: __MODULE__.CoverageCollaborator,
      mutation: MutagenEx.MutationRunner
    }

    prior_cwd = File.cwd!()
    File.cd!(@lane_project_dir)

    try do
      Process.put(:determinism_capture_target, this)
      Process.put(:determinism_capture_ref, ref)

      _ =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          ExUnit.CaptureIO.capture_io(fn ->
            try do
              Mix.Tasks.Mutagen.run(argv, dispatch)
            rescue
              e ->
                send(this, {:determinism_raised, ref, Exception.message(e), __STACKTRACE__})
            catch
              kind, value ->
                send(this, {:determinism_caught, ref, kind, value})
            end
          end)
        end)

      receive do
        {:determinism_io, ^ref, iodata, _exit_code} ->
          IO.iodata_to_binary(iodata)

        {:determinism_raised, ^ref, message, _trace} ->
          flunk("pipeline raised: " <> message)

        {:determinism_caught, ^ref, kind, value} ->
          flunk("pipeline caught: #{inspect(kind)} #{inspect(value)}")
      after
        300_000 ->
          flunk("pipeline did not emit JSON within 300s")
      end
    after
      File.cd!(prior_cwd)
      Process.delete(:determinism_capture_target)
      Process.delete(:determinism_capture_ref)
    end
  end

  defmodule CaptureIoCollaborator do
    @moduledoc false
    @behaviour MutagenEx.Pipeline.IoFacade

    @impl MutagenEx.Pipeline.IoFacade
    def emit(iodata, exit_code, _config) do
      case Process.get(:determinism_capture_target) do
        target when is_pid(target) ->
          ref = Process.get(:determinism_capture_ref)
          send(target, {:determinism_io, ref, iodata, exit_code})
          :ok

        _ ->
          IO.write(iodata)
      end
    end
  end

  defmodule BaselineCollaborator do
    @moduledoc false
    @behaviour MutagenEx.Pipeline.BaselineFacade

    @impl MutagenEx.Pipeline.BaselineFacade
    def run(input) do
      MutagenEx.DeterminismTest.register_test_modules_for_phase!(input.test_filter.files)
      MutagenEx.Baseline.run(input)
    end
  end

  defmodule CoverageCollaborator do
    @moduledoc false
    @behaviour MutagenEx.Pipeline.CoverageFacade

    @impl MutagenEx.Pipeline.CoverageFacade
    def run(input) do
      MutagenEx.DeterminismTest.register_test_modules_for_phase!(input.test_filter.files)
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
  # State reset between runs — same recipe as `EndToEndTest.reset_e2e_state!/1`
  # so the second run starts from the same Code.Server / cover / ExUnit state
  # as the first.
  # ---------------------------------------------------------------------------

  defp reset_pipeline_state!(ctx) do
    try do
      apply(:cover, :stop, [])
    rescue
      _ -> :ok
    catch
      _, _ -> :ok
    end

    case Map.fetch(ctx, :compiled_modules) do
      {:ok, modules} when is_list(modules) ->
        Enum.each(modules, fn mod ->
          _ = :code.purge(mod)
          _ = :code.delete(mod)
          _ = :code.load_file(mod)
        end)

      _ ->
        :ok
    end

    Process.delete(:determinism_capture_target)
    Process.delete(:determinism_capture_ref)

    :ok
  end

  # ---------------------------------------------------------------------------
  # Compile + load helpers — mirror EndToEndTest.compile_lane_fixture/1
  # ---------------------------------------------------------------------------

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

  defp compile_lane_fixture(ebin) do
    compiled =
      Enum.flat_map(@lane_fixture_files, fn f ->
        path = Path.join(@lane_lib_dir, f)
        Code.compile_file(path)
      end)

    for {mod, bin} <- compiled do
      File.write!(Path.join(ebin, "#{mod}.beam"), bin)
    end

    for {mod, _bin} <- compiled do
      :code.purge(mod)
      :code.delete(mod)

      case :code.load_file(mod) do
        {:module, ^mod} ->
          :ok

        other ->
          flunk("could not reload #{inspect(mod)} from disk: #{inspect(other)}")
      end
    end

    modules = Enum.map(compiled, fn {mod, _bin} -> mod end)

    pre_md5 =
      for mod <- modules, into: %{} do
        {mod, mod.__info__(:md5)}
      end

    {modules, pre_md5}
  end

  # ---------------------------------------------------------------------------
  # Diff window helper — when the test fails, show the bytes around the
  # first divergence so the failure message points the reader at what
  # changed (rather than dumping two multi-kB blobs).
  # ---------------------------------------------------------------------------

  defp first_diff_window(b1, b2) do
    idx = first_diff_index(b1, b2, 0)

    case idx do
      :equal ->
        "(no byte difference — assertion failed for some other reason)"

      i ->
        window = 60
        start_at = max(i - window, 0)
        len = window * 2

        seg1 = safe_slice(b1, start_at, len)
        seg2 = safe_slice(b2, start_at, len)

        """
        first differing byte at offset #{i}
        run1: #{inspect(seg1)}
        run2: #{inspect(seg2)}
        """
    end
  end

  defp first_diff_index(<<a, rest1::binary>>, <<a, rest2::binary>>, n) do
    first_diff_index(rest1, rest2, n + 1)
  end

  defp first_diff_index(<<>>, <<>>, _n), do: :equal
  defp first_diff_index(_b1, _b2, n), do: n

  defp safe_slice(bin, start, len) when byte_size(bin) > start do
    take = min(len, byte_size(bin) - start)
    binary_part(bin, start, take)
  end

  defp safe_slice(_bin, _start, _len), do: <<>>
end
