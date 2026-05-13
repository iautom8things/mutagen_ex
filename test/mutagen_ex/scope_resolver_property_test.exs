defmodule MutagenEx.ScopeResolverPropertyTest do
  @moduledoc """
  Property-style tests for `MutagenEx.ScopeResolver.resolve/2`.

  Covers `mutagen.scope_resolution.v3` (the property-test verification stub
  in `.spec/specs/scope_resolution.spec.md`).

  ## The invariant

  For any synthesized small Elixir source — a single `defmodule` with N
  randomly-generated `def fn/arity` clauses — the resolver MUST return either:

    1. a structured error tuple, OR
    2. an `{:ok, [%Scope{}]}` whose `line_range` contains the source line of
       the targeted clause (for MFA targets) or the entire defmodule block
       (for file / module targets).

  This is the "range contains the target" invariant from the ticket: the
  resolver may legitimately refuse, but if it succeeds, the range it returns
  must straddle the line we know the target lives on.

  ## Why not StreamData?

  This project has zero third-party dependencies (see `mix.exs`). The stage
  worktree's `Allowed touches` list does not include `mix.exs`, so adding a
  test-only dep is out of scope. We use the BEAM's built-in `:rand` with a
  fixed seed and a fixed iteration count (`@iterations`) to get deterministic
  property-style coverage — re-running the test reproduces the same inputs
  in the same order, which is what falsifiability needs.
  """

  use ExUnit.Case, async: true

  alias MutagenEx.ScopeResolver
  alias MutagenEx.ScopeResolver.Scope

  @iterations 200
  @seed {1234, 5678, 9012}

  setup do
    :rand.seed(:exsss, @seed)
    :ok
  end

  describe "invariant: resolver returns error OR a range containing the target" do
    test "file target — range covers every def's source line" do
      for _ <- 1..@iterations do
        {source, _module_name, defs} = synthesize_module()
        def_lines = Enum.map(defs, fn {_fun, _arity, line} -> line end)
        loader = fn "lib/synth.ex" -> source end

        case ScopeResolver.resolve("lib/synth.ex", loader: loader) do
          {:error, _reason, _details} ->
            # Synthesis can produce edge cases (e.g. empty body); error is
            # an allowed outcome per the invariant.
            :ok

          {:ok, []} ->
            # File with no defmodule (synthesis can't currently produce this,
            # but it's a valid resolver outcome we accept defensively).
            :ok

          {:ok, [%Scope{line_range: range} | _]} ->
            # Every def we generated must lie within the returned defmodule
            # range. If any def is outside the range, the resolver lied
            # about where the module lives.
            for line <- def_lines do
              assert line in range,
                     "def at line #{line} should be inside defmodule range #{inspect(range)};\nsource was:\n#{source}"
            end
        end
      end
    end

    test "module target — range covers every def's source line" do
      for _ <- 1..@iterations do
        {source, module_name, defs} = synthesize_module()
        def_lines = Enum.map(defs, fn {_fun, _arity, line} -> line end)
        loader = fn "lib/synth.ex" -> source end

        case ScopeResolver.resolve(module_name,
               loader: loader,
               source_files: ["lib/synth.ex"]
             ) do
          {:error, _reason, _details} ->
            :ok

          {:ok, [%Scope{line_range: range}]} ->
            for line <- def_lines do
              assert line in range,
                     "def at line #{line} should be inside module range #{inspect(range)};\nsource was:\n#{source}"
            end
        end
      end
    end

    test "MFA target — range contains the targeted clause's source line" do
      for _ <- 1..@iterations do
        {source, module_name, defs} = synthesize_module_with_clauses()

        case defs do
          [] ->
            :ok

          _ ->
            {fun_name, arity, clause_line} = Enum.random(defs)
            loader = fn "lib/synth.ex" -> source end
            target = "#{module_name}.#{fun_name}/#{arity}"

            case ScopeResolver.resolve(target,
                   loader: loader,
                   source_files: ["lib/synth.ex"]
                 ) do
              {:error, _reason, _details} ->
                :ok

              {:ok, [%Scope{line_range: range}]} ->
                assert clause_line in range,
                       "MFA clause #{target} on line #{clause_line} should be inside range #{inspect(range)};\nsource was:\n#{source}"
            end
        end
      end
    end

    test "MFA target with wrong arity never returns ok" do
      for _ <- 1..@iterations do
        {source, module_name, defs} = synthesize_module_with_clauses()
        loader = fn "lib/synth.ex" -> source end

        # Construct an arity that is NOT in the generated defs.
        used_arities = defs |> Enum.map(fn {_n, a, _l} -> a end) |> MapSet.new()
        # arities go 0..3 in synthesis; pick something definitely outside.
        unused_arity = 99

        unused_fun =
          case defs do
            [{fun, _a, _l} | _] -> fun
            [] -> :missing
          end

        target = "#{module_name}.#{unused_fun}/#{unused_arity}"

        # The arity 99 cannot occur, so the result MUST be an error.
        case ScopeResolver.resolve(target,
               loader: loader,
               source_files: ["lib/synth.ex"]
             ) do
          {:error, reason, _details} ->
            assert reason in [
                     :function_not_found,
                     :module_not_found,
                     :unrecognised_target
                   ]

          {:ok, _} ->
            flunk(
              "expected error for unused arity, got ok; used_arities=#{inspect(used_arities)}, source=#{source}"
            )
        end
      end
    end

    test "no on-disk side effects across all random inputs" do
      refute Process.whereis(:cover_server)

      for _ <- 1..@iterations do
        {source, _module_name, _defs} = synthesize_module()
        loader = fn "lib/synth.ex" -> source end
        _ = ScopeResolver.resolve("lib/synth.ex", loader: loader)
      end

      refute Process.whereis(:cover_server)
      refute File.exists?("cover")
    end
  end

  # --- synthesis -------------------------------------------------------------

  # Generate a synthetic module with 0..5 simple `def fun(args), do: arg`
  # clauses. Returns `{source_string, module_name_string, [def_line_numbers]}`.
  defp synthesize_module do
    module_name = "Synth#{:rand.uniform(1_000_000)}"
    n_defs = :rand.uniform(6) - 1
    build_module(module_name, n_defs)
  end

  # Same as above but always generates 1..5 defs so the MFA test always has a
  # clause to pick.
  defp synthesize_module_with_clauses do
    module_name = "Synth#{:rand.uniform(1_000_000)}"
    n_defs = :rand.uniform(5)
    build_module(module_name, n_defs)
  end

  defp build_module(module_name, n_defs) do
    indices = if n_defs == 0, do: [], else: Enum.to_list(1..n_defs//1)

    {defs, body_lines} =
      Enum.reduce(indices, {[], []}, fn _, {defs_acc, body_acc} ->
        line_count = length(body_acc)
        # The defmodule line is line 1; body starts at line 2.
        next_line = 2 + line_count

        fun = "f#{:rand.uniform(1_000)}"
        arity = :rand.uniform(4) - 1

        args =
          if arity == 0 do
            ""
          else
            1..arity//1 |> Enum.map(fn i -> "a#{i}" end) |> Enum.join(", ")
          end

        ret = if arity > 0, do: "a1", else: ":ok"

        def_line =
          if arity == 0 do
            "  def #{fun}, do: #{ret}"
          else
            "  def #{fun}(#{args}), do: #{ret}"
          end

        entry = {String.to_atom(fun), arity, next_line}
        {[entry | defs_acc], body_acc ++ [def_line]}
      end)

    body = Enum.join(body_lines, "\n")

    source =
      if body == "" do
        "defmodule #{module_name} do\nend\n"
      else
        "defmodule #{module_name} do\n#{body}\nend\n"
      end

    {source, module_name, Enum.reverse(defs)}
  end
end
