defmodule MutagenEx.Test.FacadesTest do
  @moduledoc """
  Conformance tests for the test-seam facades introduced by
  bw mutagen-wrd.24.

  Subjects advanced: `mutagen.mutation_pipeline`, `mutagen.coverage`.

  The facades exist to give the runner / baseline / coverage / loop
  call sites a compile-time `@behaviour`-typed dispatch surface instead
  of `apply(Map.get(cfg, :facade, ProductionMod), :fun, [args])`. These
  tests assert two falsifiable properties:

    1. **Behaviour declaration.** Each default implementation declares
       `@behaviour MutagenEx.Test.<X>Facade` (the production default
       satisfies the contract its callers depend on).
    2. **Callback contract.** Each behaviour exports the documented
       callbacks with the expected arity (a missing or misnamed
       callback would surface here, not in a remote integration test).

  Together these protect against silent drift in the facade contract:
  changing a callback name without updating callers, or dropping
  `@behaviour` from a default and losing the Dialyzer leverage the
  facade exists to provide.
  """

  use ExUnit.Case, async: true

  describe "MutagenEx.Test.ExUnit (default ExUnitFacade impl)" do
    test "declares the behaviour" do
      assert MutagenEx.Test.ExUnitFacade in behaviours(MutagenEx.Test.ExUnit)
    end

    test "exports configure/1 and run/0 (the documented callbacks)" do
      callbacks = MapSet.new(MutagenEx.Test.ExUnitFacade.behaviour_info(:callbacks))
      assert MapSet.member?(callbacks, {:configure, 1})
      assert MapSet.member?(callbacks, {:run, 0})

      assert exports?(MutagenEx.Test.ExUnit, :configure, 1)
      assert exports?(MutagenEx.Test.ExUnit, :run, 0)
    end
  end

  describe "MutagenEx.Test.ExUnitServer (default ExUnitServerFacade impl)" do
    test "declares the behaviour" do
      assert MutagenEx.Test.ExUnitServerFacade in behaviours(MutagenEx.Test.ExUnitServer)
    end

    test "exports add_module/2" do
      callbacks = MapSet.new(MutagenEx.Test.ExUnitServerFacade.behaviour_info(:callbacks))
      assert MapSet.member?(callbacks, {:add_module, 2})

      assert exports?(MutagenEx.Test.ExUnitServer, :add_module, 2)
    end
  end

  describe "MutagenEx.Test.CaptureIo (default CaptureIoFacade impl)" do
    test "declares the behaviour" do
      assert MutagenEx.Test.CaptureIoFacade in behaviours(MutagenEx.Test.CaptureIo)
    end

    test "exports with_io/2" do
      callbacks = MapSet.new(MutagenEx.Test.CaptureIoFacade.behaviour_info(:callbacks))
      assert MapSet.member?(callbacks, {:with_io, 2})

      assert exports?(MutagenEx.Test.CaptureIo, :with_io, 2)
    end

    test "with_io/2 returns {result, captured} shape over real ExUnit.CaptureIO" do
      {result, output} =
        MutagenEx.Test.CaptureIo.with_io(:stderr, fn ->
          IO.write(:stderr, "warned\n")
          :returned
        end)

      assert result == :returned
      assert output =~ "warned"
    end
  end

  describe "MutagenEx.Test.Compiler (default CompilerFacade impl)" do
    test "declares the behaviour" do
      assert MutagenEx.Test.CompilerFacade in behaviours(MutagenEx.Test.Compiler)
    end

    test "exports compile_quoted/2" do
      callbacks = MapSet.new(MutagenEx.Test.CompilerFacade.behaviour_info(:callbacks))
      assert MapSet.member?(callbacks, {:compile_quoted, 2})

      assert exports?(MutagenEx.Test.Compiler, :compile_quoted, 2)
    end
  end

  describe "MutationRunner :compiler seam — back-compat for legacy {mod, fun} tuple" do
    # bw mutagen-wrd.24's contract: tests that historically passed
    # `:compiler` as `{mod, fun}` keep working. The new shape (plain
    # module atom implementing `MutagenEx.Test.CompilerFacade`) is
    # honored alongside the legacy tuple. This test pins both shapes
    # — a regression that dropped the tuple branch would fail HERE
    # rather than silently in the downstream mutation_runner_test.exs.

    defmodule LegacyCompilerStub do
      @moduledoc false

      def compile_quoted(_ast, _file) do
        Process.put(:legacy_compiler_called, true)
        []
      end
    end

    defmodule BehaviourCompilerStub do
      @moduledoc false
      @behaviour MutagenEx.Test.CompilerFacade

      @impl MutagenEx.Test.CompilerFacade
      def compile_quoted(_ast, _file) do
        Process.put(:behaviour_compiler_called, true)
        []
      end
    end

    setup do
      Process.delete(:legacy_compiler_called)
      Process.delete(:behaviour_compiler_called)
      :ok
    end

    test "module-atom shape (preferred) is dispatched as `mod.compile_quoted(ast, file)`" do
      run_one_site(%{compiler: BehaviourCompilerStub})

      assert Process.get(:behaviour_compiler_called) == true,
             "expected the behaviour-implementing module atom to be called via direct dispatch"

      refute Process.get(:legacy_compiler_called),
             "the legacy module must NOT be invoked when we asked for the behaviour shape"
    end

    test "legacy {mod, fun} tuple is still dispatched via apply/3" do
      run_one_site(%{compiler: {LegacyCompilerStub, :compile_quoted}})

      assert Process.get(:legacy_compiler_called) == true,
             "expected the legacy {mod, fun} tuple to dispatch through the apply/3 fallback"

      refute Process.get(:behaviour_compiler_called),
             "behaviour stub should not have been touched on the legacy path"
    end

    # Helper — drive a single-site MutationRunner.run/1 with the given
    # compiler-seam override. Other facade seams use behaviour-impl
    # stubs so we exercise the production dispatch path everywhere
    # except the compiler.
    defp run_one_site(overrides) do
      alias MutagenEx.MutationEnumerator.Site
      alias MutagenEx.MutationRunner
      alias MutagenEx.ScopeResolver.Scope
      alias MutagenEx.TestSelector.TestFilter

      file = "synthetic/foo.ex"

      site = %Site{
        id: "syn:1:arith",
        file: file,
        line: 2,
        column: 13,
        mutator: :arith,
        original_ast: {:+, [line: 2, column: 13], [1, 2]},
        mutated_ast: {:-, [line: 2, column: 13], [1, 2]}
      }

      file_ast =
        {:defmodule, [line: 1, column: 1],
         [
           {:__aliases__, [line: 1], [:Synthetic, :Foo]},
           [
             do:
               {:def, [line: 2, column: 3],
                [{:add, [line: 2, column: 7], []}, [do: site.original_ast]]}
           ]
         ]}

      cfg =
        %{
          seed: 0,
          timeout_ms: 500,
          test_filter: %TestFilter{include: [], exclude: [:test], files: []},
          ast_cache: %{file => {file_ast, "synthetic\n"}},
          sites: [site],
          scope_records: [%Scope{file: file, line_range: 1..3, module: Synthetic.Foo}],
          test_modules: [
            {Some.TestModule, %{async?: false, group: nil, parameterize: nil}}
          ],
          ex_unit: __MODULE__.NoopExUnit,
          ex_unit_server: __MODULE__.NoopExUnitServer,
          capture_io: MutagenEx.Test.CaptureIo
        }
        |> Map.merge(overrides)

      MutationRunner.run(cfg)
    end

    defmodule NoopExUnit do
      @moduledoc false
      @behaviour MutagenEx.Test.ExUnitFacade

      @impl MutagenEx.Test.ExUnitFacade
      def configure(_), do: :ok

      @impl MutagenEx.Test.ExUnitFacade
      def run, do: %{failures: 0, total: 1, excluded: 0, skipped: 0}
    end

    defmodule NoopExUnitServer do
      @moduledoc false
      @behaviour MutagenEx.Test.ExUnitServerFacade

      @impl MutagenEx.Test.ExUnitServerFacade
      def add_module(_, _), do: :ok
    end
  end

  describe "MutagenEx.Test.Cover (default CoverFacade impl)" do
    test "declares the behaviour" do
      assert MutagenEx.Test.CoverFacade in behaviours(MutagenEx.Test.Cover)
    end

    test "exports start/0, stop/0, compile_beam/1, analyse/3" do
      callbacks = MapSet.new(MutagenEx.Test.CoverFacade.behaviour_info(:callbacks))
      assert MapSet.member?(callbacks, {:start, 0})
      assert MapSet.member?(callbacks, {:stop, 0})
      assert MapSet.member?(callbacks, {:compile_beam, 1})
      assert MapSet.member?(callbacks, {:analyse, 3})

      assert exports?(MutagenEx.Test.Cover, :start, 0)
      assert exports?(MutagenEx.Test.Cover, :stop, 0)
      assert exports?(MutagenEx.Test.Cover, :compile_beam, 1)
      assert exports?(MutagenEx.Test.Cover, :analyse, 3)
    end
  end

  # Helper: a module's declared behaviours are listed in its
  # `__info__(:attributes)` under the `:behaviour` key. Returns a list
  # of module atoms (potentially empty).
  defp behaviours(module) do
    module.__info__(:attributes)
    |> Keyword.get_values(:behaviour)
    |> List.flatten()
  end

  # Helper: `function_exported?/3` returns false until the target module
  # is loaded; `Code.ensure_loaded/1` forces the load before the check.
  # We use this rather than naked `function_exported?` so the test stays
  # honest under the lazy-load semantics of the BEAM.
  defp exports?(module, fun, arity) do
    Code.ensure_loaded(module)
    function_exported?(module, fun, arity)
  end
end
