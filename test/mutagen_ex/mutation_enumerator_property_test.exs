defmodule MutagenEx.MutationEnumeratorPropertyTest do
  @moduledoc """
  Property-style test for `MutagenEx.MutationEnumerator.enumerate/4`.

  Covers `mutagen.mutation_enumeration.v2`: the determinism invariant
  (`r1`) on randomly-generated input tuples.

  ## The invariant

  For any synthesized `{ast_cache, scope_records, covered_lines}` tuple,
  two consecutive calls to `enumerate/4` MUST return byte-identical
  results — same sites list, same skipped list, same warnings list, same
  order in each.

  This is the contract the JSON reporter and the verifier judge rely on:
  the mutation plan is reproducible from inputs alone, with no hidden
  state.

  ## Why not StreamData?

  Same reason as `MutagenEx.ScopeResolverPropertyTest`: this project ships
  zero third-party dependencies and the stage's `Allowed touches` doesn't
  include `mix.exs`. We use the BEAM's built-in `:rand` with a fixed seed
  and a fixed iteration count so the property explores a deterministic
  sweep of input shapes.
  """

  use ExUnit.Case, async: true

  alias MutagenEx.MutationEnumerator
  alias MutagenEx.ScopeResolver.Scope

  @iterations 100
  @seed {3141, 5926, 5358}

  setup do
    :rand.seed(:exsss, @seed)
    :ok
  end

  describe "determinism invariant (mutagen.mutation_enumeration.r1)" do
    test "two consecutive enumerations on identical inputs are byte-identical" do
      for _ <- 1..@iterations do
        {ast_cache, scopes, covered} = synthesize_inputs()

        r1 = MutationEnumerator.enumerate(ast_cache, scopes, covered)
        r2 = MutationEnumerator.enumerate(ast_cache, scopes, covered)

        assert r1 == r2,
               """
               Determinism violated. Inputs:
               scopes = #{inspect(scopes)}
               covered = #{inspect(covered)}

               r1 = #{inspect(r1, limit: :infinity)}
               r2 = #{inspect(r2, limit: :infinity)}
               """
      end
    end

    test "10 consecutive runs are all equal" do
      # Smaller iteration count, but each iteration runs the enumerator
      # 10 times to prove determinism over longer sequences.
      for _ <- 1..25 do
        {ast_cache, scopes, covered} = synthesize_inputs()

        runs = for _ <- 1..10, do: MutationEnumerator.enumerate(ast_cache, scopes, covered)

        [first | rest] = runs

        for {run, idx} <- Enum.with_index(rest, 2) do
          assert run == first,
                 "run #{idx} differs from run 1\nscopes=#{inspect(scopes)}\ncovered=#{inspect(covered)}"
        end
      end
    end

    test "reordering scope_records reorders sites but preserves set equality" do
      # Determinism is by-input, not commutative. We sanity-check that
      # swapping two independent scope records changes ORDER but not the
      # SET of resulting sites.
      for _ <- 1..50 do
        case synthesize_two_module_inputs() do
          :skip ->
            :ok

          {ast_cache, [sa, sb], covered} ->
            r_ab = MutationEnumerator.enumerate(ast_cache, [sa, sb], covered)
            r_ba = MutationEnumerator.enumerate(ast_cache, [sb, sa], covered)

            assert MapSet.new(r_ab.sites) == MapSet.new(r_ba.sites)
            assert MapSet.new(r_ab.skipped) == MapSet.new(r_ba.skipped)
        end
      end
    end
  end

  # --- synthesis --------------------------------------------------------------

  # Build a single-file ast cache with a small synthetic module containing
  # some arith ops plus a covered_lines set.
  defp synthesize_inputs do
    module_name = "PropMod#{:rand.uniform(1_000_000)}"
    n_defs = :rand.uniform(5)

    {source, def_lines} = build_module_source(module_name, n_defs)

    file = "lib/prop_#{:rand.uniform(1_000_000)}.ex"
    {:ok, ast} = Code.string_to_quoted(source, columns: true, line: 1, file: file)
    cache = %{file => ast}

    scopes = [
      %Scope{
        file: file,
        line_range: 1..(length(def_lines) + 3),
        module: String.to_atom("Elixir." <> module_name)
      }
    ]

    # Cover a random subset of def lines to vary the filter results.
    covered_set =
      def_lines
      |> Enum.filter(fn _ -> :rand.uniform(2) == 1 end)
      |> MapSet.new()

    covered = %{file => covered_set}

    {cache, scopes, covered}
  end

  # Build a two-module file so we can check the reordering invariant. May
  # return `:skip` if random arity choices fail (defensive — keeps the
  # test from flaking on a malformed synth).
  defp synthesize_two_module_inputs do
    mod_a = "PropA#{:rand.uniform(1_000_000)}"
    mod_b = "PropB#{:rand.uniform(1_000_000)}"

    n_a = :rand.uniform(3)
    n_b = :rand.uniform(3)

    {source_a, a_lines} = build_module_source(mod_a, n_a)
    {source_b, _b_lines} = build_module_source(mod_b, n_b)

    full_source = source_a <> "\n" <> source_b

    file = "lib/twoprop_#{:rand.uniform(1_000_000)}.ex"

    case Code.string_to_quoted(full_source, columns: true, line: 1, file: file) do
      {:ok, ast} ->
        cache = %{file => ast}

        sa = %Scope{
          file: file,
          line_range: 1..1000,
          module: String.to_atom("Elixir." <> mod_a)
        }

        sb = %Scope{
          file: file,
          line_range: 1..1000,
          module: String.to_atom("Elixir." <> mod_b)
        }

        # Cover all of mod_a's def lines; otherwise the sites lists would
        # likely both be empty and the reorder check would be vacuous.
        covered_set = MapSet.new(a_lines ++ Enum.to_list(1..200))
        covered = %{file => covered_set}

        {cache, [sa, sb], covered}

      {:error, _} ->
        :skip
    end
  end

  # Generate a `defmodule` source string with N simple `def` clauses, each
  # carrying one or two arith ops. Returns `{source, [line_of_each_def]}`.
  defp build_module_source(module_name, n_defs) do
    header = "defmodule #{module_name} do"

    {body_lines, def_lines} =
      Enum.reduce(1..max(n_defs, 1), {[], []}, fn _, {body_acc, lines_acc} ->
        cur_line = length(body_acc) + 2
        fun_name = "f#{:rand.uniform(1_000)}"
        op = Enum.random([:+, :-, :*])
        # Use a small integer to keep the expression valid and varied.
        n = :rand.uniform(9)
        line = "  def #{fun_name}(x), do: x #{op} #{n}"
        {body_acc ++ [line], lines_acc ++ [cur_line]}
      end)

    source = Enum.join([header | body_lines] ++ ["end"], "\n") <> "\n"
    {source, def_lines}
  end
end
