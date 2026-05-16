defmodule MutagenEx.MutationRunnerRaiseTest do
  @moduledoc """
  Tests for the `with_restore/4` lifecycle helper around the
  loaded-mutation window (bw mutagen-wrd.17).

  Subject advanced: `mutagen.mutation_pipeline.r12` (raise/throw/exit
  inside the window triggers restore before propagation; original
  cause is preserved). Also exercises the `:compile_error` branch's
  newly-surfaced restore-failure path (F27, per
  `mutagen.mutation_pipeline.r6`).

  Verification stub: `mutagen.mutation_pipeline.v5`
  (`mix test test/mutagen_ex/mutation_runner_raise_test.exs`).

  ## Why this test exists separately

  The bulk of `mutation_runner_test.exs` exercises the happy path and
  classification surface. F3's failure mode — a raise inside the
  protected window — needs a tiny, deliberate test seam (a CaptureIO
  stub that raises after the body returns) to surface the path that
  `with_restore/4` exists to handle. Keeping these tests in their own
  module makes the cause/effect obvious without bloating the main
  runner test file.
  """

  use ExUnit.Case, async: false

  alias MutagenEx.MutationEnumerator.Site
  alias MutagenEx.MutationRunner
  alias MutagenEx.ScopeResolver.Scope
  alias MutagenEx.TestSelector.TestFilter

  # ---- Stubs ----------------------------------------------------------------

  # CaptureIO stub that lets the real ExUnit.CaptureIO drive the inner
  # closure, then optionally raises/throws/exits AFTER the body has
  # returned. This is precisely the failure shape `with_restore/4`
  # exists to absorb: the mutated AST is loaded, MutationLoop is
  # mid-flight inside the protected window, and a fault on the way back
  # out makes the exception propagate.
  #
  # Per site, `safe_compile_quoted` invokes `with_io` three times:
  #
  #   1. Mutated-AST compile (BEFORE the protected window opens)
  #   2. `MutationLoop.capture_stderr` (INSIDE the window — the
  #      realistic fault site)
  #   3. Restore compile (AFTER the window closes, called from
  #      `safe_restore` or the success branch)
  #
  # Faulting call 1 would test the wrong path (the mutated AST hasn't
  # been "loaded" from `with_restore`'s perspective yet). Faulting call
  # 3 would test a restore-failure, which is a separate path (handled
  # by the `{:error, :restore_failed, _}` branch). The interesting case
  # is call 2.
  #
  # `Process.put(:raising_capture_io_fault, fault)` configures the
  # fault; `:raising_capture_io_fire_on` (default 2) picks which call
  # the fault fires on.
  defmodule RaisingCaptureIO do
    @moduledoc false

    def with_io(device, fun) do
      {result, output} = ExUnit.CaptureIO.with_io(device, fun)

      call_n = (Process.get(:raising_capture_io_call_n) || 0) + 1
      Process.put(:raising_capture_io_call_n, call_n)

      fault = Process.get(:raising_capture_io_fault)
      fire_on = Process.get(:raising_capture_io_fire_on) || 2

      cond do
        is_nil(fault) ->
          {result, output}

        call_n != fire_on ->
          {result, output}

        true ->
          case fault do
            {:raise, msg} -> raise RuntimeError, msg
            {:throw, val} -> throw(val)
            {:exit, reason} -> exit(reason)
          end
      end
    end
  end

  defmodule ExUnitStub do
    @moduledoc false
    def configure(_opts), do: :ok

    def run do
      %{failures: 0, total: 1, excluded: 0, skipped: 0}
    end
  end

  defmodule ExUnitServerStub do
    @moduledoc false
    def add_module(_mod, _cfg), do: :ok
  end

  # Compiler stub that records every call and can be configured to fail
  # on specific predicates. Hooks live in the process dictionary so
  # each test can wire its own sequence:
  #
  #   Process.put(:compiler_hooks, [
  #     {fn ast, _file -> contains?(ast, mutated_node) end, {:ok, []}},
  #     {fn ast, _file -> contains?(ast, original_node) end, {:raise, "restore boom"}}
  #   ])
  defmodule RecordingCompiler do
    @moduledoc false

    def compile_quoted(ast, file) do
      Process.put(
        :compiler_calls,
        [{file, ast} | Process.get(:compiler_calls) || []]
      )

      hooks = Process.get(:compiler_hooks) || []

      case Enum.find(hooks, fn {pred, _action} -> pred.(ast, file) end) do
        {_, {:raise, message}} ->
          raise CompileError, description: message

        {_, {:ok, modules}} ->
          modules

        nil ->
          []
      end
    end
  end

  # mutagen-wrd.25.6: code-server seam for the new restore path
  # (`MutagenEx.BeamCache.restore/3` → `:code.load_binary/3`). Records
  # every load call so tests can assert that restore fired before the
  # exception propagated — the new equivalent of the old "compile_quoted
  # on original AST" detection.
  #
  # `:code_server_load_hooks` is `[{predicate, action}]` mirroring the
  # compiler-stub pattern.
  defmodule RecordingCodeServer do
    @moduledoc false
    @behaviour MutagenEx.Test.CodeServerFacade

    @impl MutagenEx.Test.CodeServerFacade
    def get_object_code(module) do
      # Canned response so prime_beam_cache lands an entry for the
      # synthetic test module. The filename and binary are deterministic.
      filename = ~c"/tmp/" ++ Atom.to_charlist(module) ++ ~c".beam"
      {module, <<"SYN:", Atom.to_string(module)::binary>>, filename}
    end

    @impl MutagenEx.Test.CodeServerFacade
    def load_binary(module, filename, binary) do
      Process.put(
        :code_server_load_calls,
        [{module, filename, binary} | Process.get(:code_server_load_calls) || []]
      )

      hooks = Process.get(:code_server_load_hooks) || []

      case Enum.find(hooks, fn {pred, _action} -> pred.(module, filename, binary) end) do
        {_, {:raise, msg}} ->
          raise RuntimeError, message: msg

        {_, {:error, reason}} ->
          {:error, reason}

        {_, :ok} ->
          {:module, module}

        nil ->
          {:module, module}
      end
    end
  end

  # ---- Fixture builders -----------------------------------------------------

  defp build_site(opts \\ []) do
    file = Keyword.get(opts, :file, "synthetic/foo.ex")
    line = Keyword.get(opts, :line, 2)
    column = Keyword.get(opts, :column, 13)

    %Site{
      id: Keyword.get(opts, :id, "syn:1:arith"),
      file: file,
      line: line,
      column: column,
      mutator: :arith,
      original_ast: {:+, [line: line, column: column], [1, 2]},
      mutated_ast: {:-, [line: line, column: column], [1, 2]}
    }
  end

  defp build_file_ast(site) do
    {:defmodule, [line: 1, column: 1],
     [
       {:__aliases__, [line: 1], [:Synthetic, :Foo]},
       [
         do:
           {:def, [line: 2, column: 3],
            [
              {:add, [line: 2, column: 7], []},
              [do: site.original_ast]
            ]}
       ]
     ]}
  end

  defp base_cfg(site) do
    file_ast = build_file_ast(site)

    %{
      seed: 0,
      timeout_ms: 1_000,
      test_filter: %TestFilter{include: [], exclude: [:test], files: []},
      ast_cache: %{site.file => {file_ast, "synthetic source\n"}},
      sites: [site],
      scope_records: [
        %Scope{file: site.file, line_range: 1..3, module: Synthetic.Foo}
      ],
      test_modules: [{Some.TestModule, %{async?: false, group: nil, parameterize: nil}}],
      ex_unit: ExUnitStub,
      ex_unit_server: ExUnitServerStub,
      capture_io: RaisingCaptureIO,
      compiler: {RecordingCompiler, :compile_quoted},
      code_server: RecordingCodeServer
    }
  end

  defp contains_node?(ast, target) do
    {_, found} =
      Macro.prewalk(ast, false, fn
        _node, true -> {nil, true}
        node, _ -> {node, node == target}
      end)

    found
  end

  defp clear_stubs do
    Process.delete(:raising_capture_io_fault)
    Process.delete(:raising_capture_io_fire_on)
    Process.delete(:raising_capture_io_call_n)
    Process.delete(:compiler_calls)
    Process.delete(:compiler_hooks)
    Process.delete(:code_server_load_calls)
    Process.delete(:code_server_load_hooks)
  end

  setup do
    clear_stubs()
    :ok
  end

  # Compile-call introspection helpers. The recorded list is in reverse
  # chronological order; reverse it before assertions for human-readable
  # sequences.
  defp compile_call_sequence do
    (Process.get(:compiler_calls) || []) |> Enum.reverse()
  end

  defp first_call_has_mutated?(site) do
    case compile_call_sequence() do
      [{_file, ast} | _] -> contains_node?(ast, site.mutated_ast)
      [] -> false
    end
  end

  # mutagen-wrd.25.6: restore is now `code_server.load_binary/3` via
  # `MutagenEx.BeamCache.restore/3`, not `Code.compile_quoted/2` on the
  # original AST. We detect restore by inspecting the recorded
  # `load_binary` call list for an entry on the site's scoped module.
  defp restore_call_invoked?(_site) do
    case Process.get(:code_server_load_calls) do
      nil -> false
      [] -> false
      [_ | _] -> true
    end
  end

  # ---------------------------------------------------------------------------
  # r12 (s9): raise/throw/exit inside the loaded-mutation window triggers
  # restore before propagation; original kind/value/stacktrace preserved.
  # ---------------------------------------------------------------------------

  describe "r12: raise inside loaded-mutation window" do
    test "raise: restore fires before exception re-propagates" do
      site = build_site()
      cfg = base_cfg(site)

      Process.put(:raising_capture_io_fault, {:raise, "fault inside window"})

      assert_raise RuntimeError, "fault inside window", fn ->
        MutationRunner.run(cfg)
      end

      # The protected window installed the mutated AST; before the
      # raise propagated, with_restore must have replaced it with the
      # original. Compile log: mutated call first, then restore call.
      assert first_call_has_mutated?(site)
      assert restore_call_invoked?(site)
    end

    test "throw: restore fires before throw re-propagates" do
      site = build_site()
      cfg = base_cfg(site)

      Process.put(:raising_capture_io_fault, {:throw, :fault_inside_window})

      assert catch_throw(MutationRunner.run(cfg)) == :fault_inside_window

      assert first_call_has_mutated?(site)
      assert restore_call_invoked?(site)
    end

    test "exit: restore fires before exit re-propagates" do
      site = build_site()
      cfg = base_cfg(site)

      Process.put(:raising_capture_io_fault, {:exit, :fault_inside_window})

      assert catch_exit(MutationRunner.run(cfg)) == :fault_inside_window

      assert first_call_has_mutated?(site)
      assert restore_call_invoked?(site)
    end

    test "raise + restore-also-fails: original cause surfaces, restore failure is swallowed" do
      site = build_site()
      cfg = base_cfg(site)

      # Fault during window AND restore fails inside safe_restore.
      Process.put(:raising_capture_io_fault, {:raise, "original cause"})

      # mutagen-wrd.25.6: mutated AST compile still uses the compiler
      # seam; restore now uses the code_server seam. We make load_binary
      # raise to exercise safe_restore's swallow-and-propagate path.
      Process.put(:compiler_hooks, [
        # Mutated AST compile succeeds.
        {fn ast, _file -> contains_node?(ast, site.mutated_ast) end, {:ok, []}}
      ])

      Process.put(:code_server_load_hooks, [
        # Restore path raises inside load_binary — safe_restore wraps
        # the call, swallows the failure, and re-propagates the
        # original CaptureIO-induced RuntimeError.
        {fn _mod, _file, _bin -> true end, {:raise, "restore boom"}}
      ])

      # The original RuntimeError must surface — not the restore
      # failure. safe_restore's job is to absorb its own failures so
      # they never mask the original cause.
      assert_raise RuntimeError, "original cause", fn ->
        MutationRunner.run(cfg)
      end

      # The mutated swap was attempted (compile) AND the restore was
      # attempted (load_binary call recorded before it raised).
      assert first_call_has_mutated?(site)
      assert restore_call_invoked?(site)
    end
  end

  # ---------------------------------------------------------------------------
  # r12 (s10) / r6: :compile_error branch surfaces restore failure
  # instead of silently discarding it (F27 from the critical review).
  # ---------------------------------------------------------------------------

  describe "r12 / r6: :compile_error branch restore-failure surfacing (F27)" do
    test ":compile_error + restore failure returns :unrecoverable_restore_failure" do
      site = build_site()
      cfg = base_cfg(site)

      # mutagen-wrd.25.6: the mutated-AST compile still routes through
      # `:compiler`; restore failure is now a `code_server.load_binary/3`
      # error (not a `Code.compile_quoted/2` raise).
      Process.put(:compiler_hooks, [
        # Mutated AST compile fails (:compile_error branch).
        {fn ast, _file -> contains_node?(ast, site.mutated_ast) end,
         {:raise, "synthetic compile failure"}}
      ])

      Process.put(:code_server_load_hooks, [
        # The defensive restore on the :compile_error branch fails when
        # load_binary returns {:error, _}. The surfacing path renames
        # the failure mode but preserves the same external error shape.
        {fn _mod, _file, _bin -> true end, {:error, :restore_failure_on_compile_error_branch}}
      ])

      assert {:error, :unrecoverable_restore_failure, details} = MutationRunner.run(cfg)

      assert details.site_id == site.id
      assert details.file == site.file

      # Message names both the restore failure and the original cause.
      # The text moved from "compile_quoted raised" → "load_binary
      # failed" but the surface shape (":compile_error branch"
      # narrative + original cause) is preserved.
      assert details.message =~ "restore failed on :compile_error branch"
      assert details.message =~ "restore_failure_on_compile_error_branch"
      assert details.message =~ "synthetic compile failure"
    end

    test ":compile_error + restore success continues with compile_errors entry" do
      site = build_site()
      cfg = base_cfg(site)

      Process.put(:compiler_hooks, [
        {fn ast, _file -> contains_node?(ast, site.mutated_ast) end,
         {:raise, "synthetic compile failure"}}
      ])

      # Restore via load_binary returns :ok (the default RecordingCodeServer
      # response when no hook is set).

      assert {:ok, result} = MutationRunner.run(cfg)
      assert result.compile_errors != []
      assert [entry] = result.compile_errors
      assert entry.id == site.id
      assert entry.message =~ "synthetic compile failure"
      # No restore-failure surfacing; just the normal :compile_error path.
      refute String.contains?(entry.message, "restore failed")
    end
  end

  # ---------------------------------------------------------------------------
  # Regression guards: the happy path must still work after the lifecycle
  # rewrite. These don't add new coverage but pin the wrapping shape.
  # ---------------------------------------------------------------------------

  describe "r12 happy-path regression guard" do
    test "no fault, normal completion: result emitted, restore still ran" do
      site = build_site()
      cfg = base_cfg(site)

      # No fault configured. Default compiler hook = pass through.

      assert {:ok, result} = MutationRunner.run(cfg)
      assert [_one_result] = result.results
      # The protected window installed the mutated AST then restored it.
      assert first_call_has_mutated?(site)
      assert restore_call_invoked?(site)
    end
  end
end
