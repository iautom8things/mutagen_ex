defmodule MutagenEx.Integration.C1Test do
  @moduledoc """
  C1 spike — proves the core feasibility of the in-process pipeline's
  restore contract against four representative Elixir module shapes.

  Subjects advanced (see `.spec/specs/`):

  - `mutagen.coverage.r3` — after cover stop, `:code.which/1` returns a
    non-`:cover_compiled` value for every cover-instrumented module.
  - `mutagen.coverage.r7` — neither `:cover` instrumentation nor
    `Code.compile_quoted/1` restore modifies any source file on disk.
  - `mutagen.mutation_pipeline.r6` — after each per-mutation cycle, the
    original module's bytecode is restored by `Code.compile_quoted/1`
    on the cached AST; restored code passes the same assertions that
    the unmutated code passed before mutation.
  - `mutagen.mutation_pipeline.r11` — `MutationRunner.run/1` does not
    modify any file on disk. The working tree is byte-identical before
    and after the runner completes (asserted here as a pipeline-shape
    property, since the runner itself ships in S5).

  Fixture modules under `test/fixtures/spike_fixture/`:

  1. `order_submitter.ex` — plain module, no `use`. The simplest case.
  2. `order_processor.ex` — `use GenServer`. The most common Elixir
     state-bearing pattern.
  3. `renderer.ex` — hand-rolled `__using__/1` registering an attribute
     with `persist: true` and injecting a callback via `@before_compile`.
     Plus a consumer (`SpikeFixture.Renderer.HtmlRenderer`) in the same
     file that exercises the macro.
  4. `encodable.ex` — `defprotocol` + struct + `defimpl`.

  Each iteration of the 100-cycle loop:

    fresh-compile → record baseline → cover.start → cover.compile_beam
    → run fixture predicates (pass) → cover.stop → assert (a)
    `:code.which/1` non-`:cover_compiled` and (b) zero leftover
    `cover_*` ETS → mutate the cached AST → `Code.compile_quoted` of
    the mutated AST → run fixture predicates (some FAIL as required by
    (d)) → restore by `Code.compile_quoted` of the original cached AST
    → assert (e) all predicates pass again → assert (c)
    `__info__(:attributes)` deltas match the fresh-compile baseline.

  Per the ticket's failure policy: any negative outcome on any of the 4
  fixture classes or on the 100-iter loop escalates to the user. This
  test does NOT silently scope-restrict; if it fails, the project's
  fallback architecture decision (child-BEAM per mutation) is needed.

  Note on `Module.get_attribute/2`: that API is compile-time only. The
  runtime equivalent for compiled modules is `<mod>.__info__(:attributes)`,
  which returns the set of persisted attributes. Invariant (c) is
  asserted against `__info__(:attributes)` — the runtime witness of
  what the spec calls "Module.get_attribute/2 deltas".
  """

  use ExUnit.Case, async: false

  @moduletag :spike
  @moduletag :integration

  # 100 restore cycles per the ticket's GATING requirement.
  @iterations 100

  @fixture_dir Path.expand("../../fixtures/spike_fixture", __DIR__)

  @fixture_files [
    "order_submitter.ex",
    "order_processor.ex",
    "renderer.ex",
    "encodable.ex"
  ]

  # Modules each file defines. The :primary key is the one whose
  # bytecode gets mutated and restored each iteration; :auxiliary lists
  # other modules in the same file that must also survive the
  # round-trip (callbacks, protocol impls, struct shells, etc.).
  @fixture_layout %{
    "order_submitter.ex" => %{
      primary: SpikeFixture.OrderSubmitter,
      auxiliary: []
    },
    "order_processor.ex" => %{
      primary: SpikeFixture.OrderProcessor,
      auxiliary: []
    },
    "renderer.ex" => %{
      primary: SpikeFixture.Renderer.HtmlRenderer,
      auxiliary: [SpikeFixture.Renderer]
    },
    "encodable.ex" => %{
      primary: SpikeFixture.EncodableImpl,
      auxiliary: [SpikeFixture.Encodable, SpikeFixture.Encodable.SpikeFixture.EncodableImpl]
    }
  }

  setup_all do
    # `:cover` lives in OTP's `tools-<vsn>/ebin` directory, not on the
    # default Mix test code path. `:code.lib_dir(:tools)` returns
    # `{:error, :bad_name}` when the `:tools` app hasn't been loaded,
    # so we resolve via `:code.root_dir/0` + wildcard. The spike must
    # self-contain this — the production `CoverageRunner` (S5) will
    # need to do the same.
    root = List.to_string(:code.root_dir())

    tools_ebin =
      case Path.wildcard(Path.join(root, "lib/tools-*/ebin")) do
        [path | _] ->
          path

        [] ->
          flunk(
            "GATING: could not locate `tools-*/ebin` under #{root}. " <>
              "`:cover` is required for the spike."
          )
      end

    Code.append_path(tools_ebin)
    {:module, :cover} = Code.ensure_loaded(:cover)

    ebin = Path.join(System.tmp_dir!(), "mutagen_ex_c1_#{System.unique_integer([:positive])}")
    File.mkdir_p!(ebin)
    Code.append_path(ebin)

    on_exit(fn ->
      Code.delete_path(ebin)
      File.rm_rf!(ebin)
    end)

    {:ok, ebin: ebin}
  end

  setup ctx do
    # Snapshot source file hashes; we will assert byte-identical state
    # at end of test (r7, r11).
    pre_hashes =
      for f <- @fixture_files, into: %{} do
        {f, :crypto.hash(:sha256, File.read!(Path.join(@fixture_dir, f)))}
      end

    on_exit(fn ->
      for f <- @fixture_files do
        post = :crypto.hash(:sha256, File.read!(Path.join(@fixture_dir, f)))
        # If this ever fires the spike has corrupted the fixture
        # source — escalate immediately.
        if post != pre_hashes[f] do
          flunk(
            "GATING: fixture source #{f} modified during C1 spike. " <>
              "Restore pipeline must not write to disk."
          )
        end
      end
    end)

    {:ok, pre_hashes: pre_hashes, ebin: ctx.ebin}
  end

  test "C1: 100 restore cycles across 4 fixture module shapes", ctx do
    # Phase 0: fresh-compile each fixture, write .beam files, capture
    # the fresh-compile attribute baseline and the cached AST.
    {:ok, layout} = prepare_fixtures(ctx.ebin)

    # Phase 1: iterate. Each iteration runs the full cover →
    # cover-stop → mutate → restore cycle for every fixture file.
    Enum.each(1..@iterations, fn iter ->
      Enum.each(@fixture_files, fn file ->
        info = Map.fetch!(layout, file)
        run_cycle!(info, file, iter)
      end)
    end)
  end

  # ---- helpers ----

  defp prepare_fixtures(ebin) do
    # `:cover.compile_beam/1` requires the `Dbgi` (abstract code)
    # chunk; without it, the call returns `{:error, {:no_abstract_code, _}}`.
    # Save and restore prior compiler options so we don't poison
    # downstream tests in the same VM.
    prior_opts = Code.compiler_options()
    Code.compiler_options(debug_info: true)

    layout =
      for file <- @fixture_files, into: %{} do
        path = Path.join(@fixture_dir, file)
        source_text = File.read!(path)

        {:ok, ast} =
          Code.string_to_quoted(source_text,
            columns: true,
            file: path
          )

        # Compile fresh to get the canonical baseline and to land
        # .beam files on disk for `:cover.compile_beam/1`.
        compiled = Code.compile_file(path)

        beam_paths =
          for {mod, bin} <- compiled do
            beam_path = Path.join(ebin, "#{mod}.beam")
            File.write!(beam_path, bin)
            {mod, beam_path}
          end

        modules = Enum.map(beam_paths, fn {mod, _} -> mod end)

        baseline_attrs =
          for mod <- modules, into: %{} do
            {mod, attribute_signature(mod)}
          end

        plan = Map.fetch!(@fixture_layout, file)

        {file,
         %{
           path: path,
           ast: ast,
           source_text: source_text,
           modules: modules,
           beam_paths: beam_paths,
           baseline_attrs: baseline_attrs,
           primary: plan.primary,
           auxiliary: plan.auxiliary
         }}
      end

    Code.compiler_options(prior_opts)

    {:ok, layout}
  end

  defp run_cycle!(info, file, iter) do
    # 1. Cover-instrument every module in this fixture file.
    cover_table_baseline = cover_ets_count()

    {:ok, _pid} = ensure_cover_started()

    for {_mod, beam_path} <- info.beam_paths do
      case apply(:cover, :compile_beam, [String.to_charlist(beam_path)]) do
        {:ok, _mod} ->
          :ok

        other ->
          flunk("GATING [#{file} iter #{iter}]: :cover.compile_beam failed: #{inspect(other)}")
      end
    end

    # Confirm cover is actually intercepting the primary module.
    case :code.which(info.primary) do
      :cover_compiled ->
        :ok

      other ->
        flunk("GATING [#{file} iter #{iter}]: expected :cover_compiled, got #{inspect(other)}")
    end

    # 2. Run the fixture's "test" predicate against cover-compiled
    # code. It must pass — the unmodified module's behavior is intact
    # under cover.
    assert_fixture_passes!(info.primary, file, iter, "cover-compiled")

    # 3. Cover stop. After stop, the cover ETS tables we observed
    # during cover should be gone (invariant b), and `:code.which`
    # must return a non-`:cover_compiled` value (invariant a).
    :ok = apply(:cover, :stop, [])

    for {mod, _beam_path} <- info.beam_paths do
      which = :code.which(mod)

      refute which == :cover_compiled,
             "GATING [#{file} iter #{iter} mod #{inspect(mod)}]: " <>
               ":code.which/1 still :cover_compiled after :cover.stop/0 — " <>
               "invariant mutagen.coverage.r3 (a) failed"
    end

    leftover_cover_ets = cover_ets_count() - cover_table_baseline

    assert leftover_cover_ets == 0,
           "GATING [#{file} iter #{iter}]: #{leftover_cover_ets} leftover cover ETS tables — " <>
             "invariant (b) failed"

    # 4. Bytecode mutation: compile a mutated AST. The mutation flips a
    # primary-module function so the fixture predicate fails.
    mutated_ast = mutate_primary!(info.ast, info.primary, info.path)

    # Suppress redefinition warnings — we know we're recompiling.
    ExUnit.CaptureIO.capture_io(:stderr, fn ->
      Code.compile_quoted(mutated_ast, info.path)
    end)

    refute_fixture_passes!(info.primary, file, iter, "post-mutation")

    # 5. Restore: compile the original cached AST. Predicate must pass
    # again — invariant (e) and `mutagen.mutation_pipeline.r6`.
    ExUnit.CaptureIO.capture_io(:stderr, fn ->
      Code.compile_quoted(info.ast, info.path)
    end)

    after_restore_which = :code.which(info.primary)

    refute after_restore_which == :cover_compiled,
           "GATING [#{file} iter #{iter}]: :code.which/1 == :cover_compiled after restore"

    assert_fixture_passes!(info.primary, file, iter, "post-restore")

    # 6. Attribute delta check (invariant c). The restored modules'
    # `__info__(:attributes)` must equal the fresh-compile baseline.
    for {mod, baseline} <- info.baseline_attrs do
      current = attribute_signature(mod)

      assert current == baseline,
             "GATING [#{file} iter #{iter} mod #{inspect(mod)}]: " <>
               "attribute signature drift — invariant (c) failed.\n" <>
               "baseline: #{inspect(baseline)}\ncurrent:  #{inspect(current)}"
    end

    :ok
  end

  defp ensure_cover_started do
    case apply(:cover, :start, []) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
    end
  end

  defp cover_ets_count do
    :ets.all()
    |> Enum.count(fn t ->
      name = :ets.info(t, :name)
      is_atom(name) and String.starts_with?(Atom.to_string(name), "cover_")
    end)
  end

  # Returns a value that captures the persistent attributes of a
  # compiled module. We exclude `:vsn`, which is the module's
  # compile-time hash — it legitimately differs between fresh compile
  # and restored compile because the AST recompile produces a new vsn
  # even though the *user-visible* attributes are identical. The spec's
  # invariant (c) is about user-visible attribute drift, not the vsn
  # tag the compiler stamps on every module.
  defp attribute_signature(mod) do
    apply(mod, :__info__, [:attributes])
    |> Enum.reject(fn {k, _v} -> k == :vsn end)
    |> Enum.sort()
  end

  # Mutates the cached AST so the primary module's behavior flips. We
  # rewrite specific literals known to live in each primary. This is
  # the spike's analogue of `MutationRunner`'s site-level swap.
  defp mutate_primary!(ast, primary_mod, _path) do
    case primary_mod do
      SpikeFixture.OrderSubmitter ->
        # Replace `:ok` literal with `:mutated` so submit/1 returns
        # `:mutated` for the happy path.
        Macro.prewalk(ast, fn
          :ok -> :mutated
          other -> other
        end)

      SpikeFixture.OrderProcessor ->
        # Replace the literal `2` in `n * 2` with `3` so double/1
        # produces `n * 3`.
        Macro.prewalk(ast, fn
          {:*, meta, [{:n, n_meta, ctx}, 2]} when is_atom(ctx) ->
            {:*, meta, [{:n, n_meta, ctx}, 3]}

          other ->
            other
        end)

      SpikeFixture.Renderer.HtmlRenderer ->
        # Replace `<html/>` literal so render(:html) returns the wrong
        # string.
        Macro.prewalk(ast, fn
          "<html/>" -> "<mutated/>"
          other -> other
        end)

      SpikeFixture.EncodableImpl ->
        # Replace the "name=" prefix so encode/1 returns the wrong
        # string.
        Macro.prewalk(ast, fn
          "name=" -> "broken="
          other -> other
        end)
    end
  end

  # Asserts the primary module behaves correctly. Each fixture has a
  # specific predicate.
  defp assert_fixture_passes!(primary, file, iter, stage) do
    result = run_fixture_predicate(primary)

    assert result == :pass,
           "GATING [#{file} iter #{iter} stage #{stage}]: " <>
             "fixture predicate did not pass: #{inspect(result)}"
  end

  defp refute_fixture_passes!(primary, file, iter, stage) do
    result = run_fixture_predicate(primary)

    refute result == :pass,
           "GATING [#{file} iter #{iter} stage #{stage}]: " <>
             "fixture predicate passed despite mutation — invariant (d) failed"
  end

  # Fixture predicates use `apply/3` rather than direct M.f(a) calls
  # so this test module compiles cleanly even though the fixture
  # modules don't exist on disk as `.beam` files until `Code.compile_file/1`
  # runs in `prepare_fixtures/1`. Direct calls trigger
  # `--warnings-as-errors` for undefined-function references.

  defp run_fixture_predicate(SpikeFixture.OrderSubmitter) do
    if apply(SpikeFixture.OrderSubmitter, :submit, [%{total: 10}]) == :ok do
      :pass
    else
      {:fail, :submit_returned_non_ok}
    end
  end

  defp run_fixture_predicate(SpikeFixture.OrderProcessor) do
    if apply(SpikeFixture.OrderProcessor, :double, [21]) == 42 do
      :pass
    else
      {:fail, :double_wrong}
    end
  end

  defp run_fixture_predicate(SpikeFixture.Renderer.HtmlRenderer) do
    mod = SpikeFixture.Renderer.HtmlRenderer

    cond do
      apply(mod, :render, [:html]) != "<html/>" ->
        {:fail, :render_html_wrong}

      # Also exercise the macro-injected callback and the persisted
      # attribute via reflection — these are the things hand-rolled
      # `__using__/1` registers, and they must survive every restore.
      apply(mod, :__renderer_kind__, []) != :registered ->
        {:fail, :renderer_kind_callback_lost}

      not Keyword.has_key?(apply(mod, :__info__, [:attributes]), :spike_renderer_kind) ->
        {:fail, :persisted_attribute_lost}

      true ->
        :pass
    end
  end

  defp run_fixture_predicate(SpikeFixture.EncodableImpl) do
    # Use `struct/2` rather than the `%Mod{}` literal so this test
    # module compiles before fixtures are loaded; the actual struct
    # module is loaded by `Code.compile_file/1` in `prepare_fixtures/1`.
    s = struct(SpikeFixture.EncodableImpl, name: "alpha")

    if apply(SpikeFixture.Encodable, :encode, [s]) == "name=alpha" do
      :pass
    else
      {:fail, :encode_wrong}
    end
  end
end
