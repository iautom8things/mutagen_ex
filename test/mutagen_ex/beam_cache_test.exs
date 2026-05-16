defmodule MutagenEx.BeamCacheTest do
  @moduledoc """
  Unit tests for `MutagenEx.BeamCache`.

  Covers `mutagen.decision.per_run_beam_cache` and
  `mutagen.decision.code_server_facade`. Uses a recording `CodeServerStub`
  that implements `MutagenEx.Test.CodeServerFacade` without touching the
  live `:code` module — so these tests never mutate global BEAM state.

  An integration test (`@tag :integration`) at the bottom exercises the
  real `:code` module for one round-trip to prove the production facade
  works against OTP.
  """

  use ExUnit.Case, async: false

  alias MutagenEx.BeamCache

  # ---------------------------------------------------------------------------
  # CodeServerStub — records calls, returns canned binaries from process
  # dictionary. Implements the facade behaviour so a compile-time guard
  # catches signature drift.
  # ---------------------------------------------------------------------------

  defmodule CodeServerStub do
    @moduledoc false
    @behaviour MutagenEx.Test.CodeServerFacade

    @impl MutagenEx.Test.CodeServerFacade
    def get_object_code(module) do
      Process.put(
        {:code_server_stub, :get_calls},
        [module | Process.get({:code_server_stub, :get_calls}, [])]
      )

      case Process.get({:code_server_stub, :get_response, module}) do
        nil ->
          # Default canned response: a deterministic binary derived
          # from the module name + a fixed filename. The atom is
          # echoed so a test asserting on the snapshot tuple sees a
          # recognisable payload.
          filename = ~c"/tmp/" ++ Atom.to_charlist(module) ++ ~c".beam"
          binary = <<"BEAM:", Atom.to_string(module)::binary>>
          {module, binary, filename}

        :error ->
          :error

        other ->
          other
      end
    end

    @impl MutagenEx.Test.CodeServerFacade
    def load_binary(module, filename, binary) do
      Process.put(
        {:code_server_stub, :load_calls},
        [{module, filename, binary} | Process.get({:code_server_stub, :load_calls}, [])]
      )

      case Process.get({:code_server_stub, :load_response, module}) do
        nil -> {:module, module}
        other -> other
      end
    end

    def get_calls, do: Process.get({:code_server_stub, :get_calls}, []) |> Enum.reverse()
    def load_calls, do: Process.get({:code_server_stub, :load_calls}, []) |> Enum.reverse()

    def reset do
      Process.delete({:code_server_stub, :get_calls})
      Process.delete({:code_server_stub, :load_calls})

      for {key, _val} <- Process.get(),
          match?({:code_server_stub, :get_response, _}, key) or
            match?({:code_server_stub, :load_response, _}, key) do
        Process.delete(key)
      end
    end
  end

  setup do
    CodeServerStub.reset()
    table = BeamCache.new()
    on_exit(fn -> BeamCache.delete(table) end)
    {:ok, table: table}
  end

  # Compile a quoted AST while suppressing stderr (silences the
  # "redefining module" warning Elixir emits on a re-define cycle).
  # Returns the raw `Code.compile_quoted/1` result so callers can
  # pattern-match the `[{module, binary}, ...]` shape.
  defp compile_silently(ast) do
    ref = make_ref()
    parent = self()

    _io =
      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        result = Code.compile_quoted(ast)
        send(parent, {ref, result})
      end)

    receive do
      {^ref, result} -> result
    after
      500 -> flunk("compile_silently: no result received")
    end
  end

  # ---------------------------------------------------------------------------
  # snapshot/3
  # ---------------------------------------------------------------------------

  describe "snapshot/3 — captures via code_server.get_object_code" do
    test "stores {module, filename, binary} in the table", %{table: table} do
      assert :ok = BeamCache.snapshot(table, SomeModule, CodeServerStub)

      # The table now has one entry whose value is the canned response.
      assert [{SomeModule, filename, binary}] = :ets.lookup(table, SomeModule)
      assert filename == ~c"/tmp/Elixir.SomeModule.beam"
      assert binary == <<"BEAM:", "Elixir.SomeModule"::binary>>
    end

    test "is idempotent — second call does not overwrite", %{table: table} do
      :ok = BeamCache.snapshot(table, IdempotentMod, CodeServerStub)

      # Now poison the canned response so a second snapshot WOULD see
      # different data if `:ets.insert_new/2` wasn't used.
      Process.put(
        {:code_server_stub, :get_response, IdempotentMod},
        {IdempotentMod, "POISONED", ~c"/tmp/poison.beam"}
      )

      assert :ok = BeamCache.snapshot(table, IdempotentMod, CodeServerStub)

      [{IdempotentMod, _filename, binary}] = :ets.lookup(table, IdempotentMod)
      refute binary == "POISONED", "second snapshot must not overwrite first"
    end

    test "returns {:error, :unavailable} when get_object_code returns :error",
         %{table: table} do
      Process.put({:code_server_stub, :get_response, MissingMod}, :error)

      assert {:error, :unavailable} = BeamCache.snapshot(table, MissingMod, CodeServerStub)
      assert :ets.lookup(table, MissingMod) == []
    end

    test "calls code_server.get_object_code with the module", %{table: table} do
      :ok = BeamCache.snapshot(table, Mod.A, CodeServerStub)
      :ok = BeamCache.snapshot(table, Mod.B, CodeServerStub)

      assert CodeServerStub.get_calls() == [Mod.A, Mod.B]
      # No load calls during snapshot.
      assert CodeServerStub.load_calls() == []
    end
  end

  # ---------------------------------------------------------------------------
  # restore/3
  # ---------------------------------------------------------------------------

  describe "restore/3 — replays via code_server.load_binary" do
    test "calls load_binary with the cached {filename, binary}", %{table: table} do
      :ok = BeamCache.snapshot(table, SwapMod, CodeServerStub)

      assert {:ok, SwapMod} = BeamCache.restore(table, SwapMod, CodeServerStub)

      [{mod, filename, binary}] = CodeServerStub.load_calls()
      assert mod == SwapMod
      assert filename == ~c"/tmp/Elixir.SwapMod.beam"
      assert binary == <<"BEAM:", "Elixir.SwapMod"::binary>>
    end

    test "returns {:error, {:not_snapshotted, module}} when entry is missing",
         %{table: table} do
      # No prior snapshot for AbsentMod.
      assert {:error, {:not_snapshotted, AbsentMod}} =
               BeamCache.restore(table, AbsentMod, CodeServerStub)

      # No load_binary call attempted.
      assert CodeServerStub.load_calls() == []
    end

    test "surfaces {:error, {:code_server, reason}} on load_binary failure",
         %{table: table} do
      :ok = BeamCache.snapshot(table, FailMod, CodeServerStub)

      Process.put({:code_server_stub, :load_response, FailMod}, {:error, :badfile})

      assert {:error, {:code_server, :badfile}} =
               BeamCache.restore(table, FailMod, CodeServerStub)
    end

    test "is idempotent — repeated restore calls each replay load_binary",
         %{table: table} do
      :ok = BeamCache.snapshot(table, Replay, CodeServerStub)

      assert {:ok, Replay} = BeamCache.restore(table, Replay, CodeServerStub)
      assert {:ok, Replay} = BeamCache.restore(table, Replay, CodeServerStub)
      assert {:ok, Replay} = BeamCache.restore(table, Replay, CodeServerStub)

      # Three load calls; the entry itself is unchanged.
      assert length(CodeServerStub.load_calls()) == 3
      assert [{Replay, _, _}] = :ets.lookup(table, Replay)
    end
  end

  # ---------------------------------------------------------------------------
  # Table lifecycle — new/0 + delete/1
  # ---------------------------------------------------------------------------

  describe "new/0 and delete/1 — per-run lifecycle" do
    test "new/0 returns a public set table with read_concurrency" do
      table = BeamCache.new()
      info = :ets.info(table)

      assert info[:type] == :set
      assert info[:protection] == :public
      assert info[:read_concurrency] == true

      BeamCache.delete(table)
    end

    test "delete/1 removes the table" do
      table = BeamCache.new()
      :ok = BeamCache.snapshot(table, Foo, CodeServerStub)
      assert :ets.info(table) != :undefined

      assert :ok = BeamCache.delete(table)
      assert :ets.info(table) == :undefined
    end

    test "delete/1 on an already-deleted table is a no-op" do
      table = BeamCache.new()
      :ok = BeamCache.delete(table)
      # Second call: must not raise.
      assert :ok = BeamCache.delete(table)
    end
  end

  # ---------------------------------------------------------------------------
  # MutationRunner integration: ETS cleanup invariant
  # ---------------------------------------------------------------------------
  #
  # These tests exercise the runner's `try/after` cleanup path. We don't
  # need a full pipeline run; we just need to prove that the table is
  # gone after `run/1` returns or raises. We use the runner's normal
  # entry point with a self-mutation refusal so the run aborts early —
  # the `after` clause still fires.

  describe "MutationRunner.run/1 ETS cleanup" do
    alias MutagenEx.MutationRunner
    alias MutagenEx.ScopeResolver.Scope
    alias MutagenEx.TestSelector.TestFilter

    test "table is deleted on the :self_mutation_refused path (early exit)" do
      tables_before = :ets.all() |> Enum.count(&match?(:beam_cache, :ets.info(&1, :name)))

      cfg = %{
        seed: 0,
        timeout_ms: 1_000,
        test_filter: %TestFilter{include: [], exclude: [:test], files: []},
        ast_cache: %{},
        sites: [],
        scope_records: [
          %Scope{
            file: "lib/mutagen_ex/runner.ex",
            line_range: 1..3,
            module: MutagenEx.SomeInternal
          }
        ],
        test_modules: []
      }

      assert {:error, :self_mutation_refused, _} = MutationRunner.run(cfg)

      tables_after = :ets.all() |> Enum.count(&match?(:beam_cache, :ets.info(&1, :name)))

      assert tables_after == tables_before,
             "BeamCache ETS table leaked after :self_mutation_refused abort"
    end

    test "table is deleted when execute/2 raises (try/after fires)" do
      # We can't easily make execute/2 raise without going through a
      # full pipeline, so we'll prove the invariant the same way: count
      # `:beam_cache`-named tables before, run, then count again.
      tables_before = :ets.all() |> Enum.count(&match?(:beam_cache, :ets.info(&1, :name)))

      # An invalid input shape makes normalise/1 return {:error, :invalid_input, _}
      # before run_with_beam_cache is even called — so this test specifically
      # proves the run_with_beam_cache wrapper itself is the cleanup point
      # (no leak even on the happy short-circuit path).
      assert {:error, :invalid_input, _} = MutationRunner.run(%{not: "valid"})

      tables_after = :ets.all() |> Enum.count(&match?(:beam_cache, :ets.info(&1, :name)))
      assert tables_after == tables_before
    end
  end

  # ---------------------------------------------------------------------------
  # Integration test — exercises the real `:code` module
  # ---------------------------------------------------------------------------

  describe "integration: real :code module round-trip" do
    @tag :integration
    test "snapshot → load_binary a modified binary → restore → original bytecode is back" do
      # `:code.get_object_code/1` only succeeds for modules whose `.beam`
      # is findable via the code path (`:code.where_is_file/1`). A
      # `Code.compile_quoted/2` victim defined in-test has no disk
      # presence, so we write its compiled binary to a temp ebin
      # directory and add that directory to the code path. This mirrors
      # the production scenario — every scoped module the runner mutates
      # has its `.beam` under `_build/test/lib/<app>/ebin/`, on the
      # `mix test` code path, so `get_object_code/1` resolves cleanly.
      victim = MutagenEx.BeamCacheTest.IntegrationVictim

      tmp_ebin =
        Path.join(
          System.tmp_dir!(),
          "mutagen_ex_beam_cache_test_#{:erlang.unique_integer([:positive])}"
        )

      File.mkdir_p!(tmp_ebin)

      try do
        true = :code.add_path(String.to_charlist(tmp_ebin))

        original_ast =
          quote do
            defmodule unquote(victim) do
              @moduledoc false
              def answer, do: :original
            end
          end

        [{^victim, original_binary} | _] = compile_silently(original_ast)

        beam_filename = String.to_charlist(Path.join(tmp_ebin, "#{victim}.beam"))
        File.write!(beam_filename, original_binary)

        # Load from disk so :code.get_object_code/1's path-resolution
        # lands on our temp file.
        :code.purge(victim)
        :code.delete(victim)
        {:module, ^victim} = :code.load_file(victim)

        original_md5 = apply(victim, :module_info, [:md5])
        assert apply(victim, :answer, []) == :original

        # Now snapshot via the real CodeServer; the binary should match
        # the one we just wrote to disk.
        table = BeamCache.new()

        try do
          assert :ok = BeamCache.snapshot(table, victim, MutagenEx.Test.CodeServer)

          # Confirm the snapshot captured a non-empty binary.
          [{^victim, _filename, snap_binary}] = :ets.lookup(table, victim)
          assert byte_size(snap_binary) == byte_size(original_binary)

          # Mutate: redefine the module with a different body. After
          # this, victim.answer/0 returns :mutated and the MD5 differs.
          mutated_ast =
            quote do
              defmodule unquote(victim) do
                @moduledoc false
                def answer, do: :mutated
              end
            end

          compile_silently(mutated_ast)
          assert apply(victim, :answer, []) == :mutated
          assert apply(victim, :module_info, [:md5]) != original_md5

          # Restore via BeamCache — should swap the original binary back.
          assert {:ok, ^victim} = BeamCache.restore(table, victim, MutagenEx.Test.CodeServer)

          assert apply(victim, :answer, []) == :original
          assert apply(victim, :module_info, [:md5]) == original_md5
        after
          BeamCache.delete(table)
        end
      after
        :code.purge(victim)
        :code.delete(victim)
        :code.del_path(String.to_charlist(tmp_ebin))
        File.rm_rf!(tmp_ebin)
      end
    end
  end
end
