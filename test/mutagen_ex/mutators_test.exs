defmodule MutagenEx.MutatorsTest do
  use ExUnit.Case, async: true

  alias MutagenEx.Mutators

  describe "catalog (mutagen.mutators.r7)" do
    test "all/0 returns exactly the ten v1 mutators in the spec's canonical order" do
      expected = [
        MutagenEx.Mutators.Arith,
        MutagenEx.Mutators.Compare,
        MutagenEx.Mutators.Boolean,
        MutagenEx.Mutators.Literal,
        MutagenEx.Mutators.WithSwap,
        MutagenEx.Mutators.CaseDrop,
        MutagenEx.Mutators.Pipeline,
        MutagenEx.Mutators.ResultTuple,
        MutagenEx.Mutators.ElseRemoval,
        MutagenEx.Mutators.GuardDrop
      ]

      assert Mutators.all() == expected
      assert length(Mutators.all()) == 10
    end

    test "names/0 returns one snake_case atom per catalog entry" do
      assert Mutators.names() == [
               :arith,
               :compare,
               :boolean,
               :literal,
               :with_swap,
               :case_drop,
               :pipeline,
               :result_tuple,
               :else_removal,
               :guard_drop
             ]
    end

    test "fetch/1 looks up a mutator module by its name" do
      assert Mutators.fetch(:arith) == MutagenEx.Mutators.Arith
      assert Mutators.fetch(:guard_drop) == MutagenEx.Mutators.GuardDrop
      assert Mutators.fetch(:nonexistent) == nil
    end
  end

  describe "behaviour callbacks (mutagen.mutators.r1)" do
    test "every catalog module exports match?/1, mutate/1, validate/1, name/0" do
      for module <- Mutators.all() do
        Code.ensure_loaded!(module)

        assert function_exported?(module, :name, 0),
               "#{inspect(module)} missing name/0"

        assert function_exported?(module, :match?, 1),
               "#{inspect(module)} missing match?/1"

        assert function_exported?(module, :mutate, 1),
               "#{inspect(module)} missing mutate/1"

        assert function_exported?(module, :validate, 1),
               "#{inspect(module)} missing validate/1"
      end
    end

    test "every catalog module's name/0 returns an atom matching its position in Mutators.names/0" do
      for {module, name} <- Enum.zip(Mutators.all(), Mutators.names()) do
        assert module.name() == name
        assert is_atom(name)
      end
    end
  end

  describe "scenario mutagen.mutators.s1 — arith + content-addressed ID" do
    test "match?/mutate/validate compose for `x + 1` and the site ID matches the spec format" do
      {:ok, ast} = Code.string_to_quoted("x + 1")

      assert MutagenEx.Mutators.Arith.match?(ast)
      mutated = MutagenEx.Mutators.Arith.mutate(ast)
      assert {:-, _, [{:x, _, nil}, 1]} = mutated
      assert MutagenEx.Mutators.Arith.validate(mutated) == :ok

      id = Mutators.site_id("lib/foo.ex", ast, :arith)
      assert id =~ ~r/^lib\/foo\.ex:\d+:arith$/
      # ID hash is `:erlang.phash2` of the *normalised* node:
      [_file, hash, _name] = String.split(id, ":")
      assert String.to_integer(hash) == :erlang.phash2(Mutators.normalize(ast))
    end
  end

  describe "scenario mutagen.mutators.s2 — with_swap detects bound_var_used_before_binding" do
    test "swapping with-clauses that bind+reference a variable yields {:skip, :bound_var_used_before_binding}" do
      {:ok, ast} =
        Code.string_to_quoted("with {:ok, a} <- f(), {:ok, b} <- g(a), do: a + b")

      assert MutagenEx.Mutators.WithSwap.match?(ast)
      swapped = MutagenEx.Mutators.WithSwap.mutate(ast)
      assert {:with, _, [{:<-, _, _}, {:<-, _, _} | _]} = swapped

      assert MutagenEx.Mutators.WithSwap.validate(swapped) ==
               {:skip, :bound_var_used_before_binding}
    end

    test "swapping independent with-clauses keeps the site (:ok)" do
      {:ok, ast} =
        Code.string_to_quoted("with {:ok, a} <- f(), {:ok, b} <- g(), do: a + b")

      assert MutagenEx.Mutators.WithSwap.match?(ast)
      swapped = MutagenEx.Mutators.WithSwap.mutate(ast)
      assert MutagenEx.Mutators.WithSwap.validate(swapped) == :ok
    end
  end

  describe "scenario mutagen.mutators.s6 — else_removal validate stays in catalog bounds" do
    test "removing the else branch from `if ... else ...` validates :ok in v1" do
      {:ok, ast} = Code.string_to_quoted("if x do :a else :b end")
      assert MutagenEx.Mutators.ElseRemoval.match?(ast)
      mutated = MutagenEx.Mutators.ElseRemoval.mutate(ast)

      assert {:if, _, [_cond, kw]} = mutated
      refute Keyword.has_key?(kw, :else)
      assert Keyword.has_key?(kw, :do)
      assert MutagenEx.Mutators.ElseRemoval.validate(mutated) == :ok
    end

    test "if-without-else does not match" do
      {:ok, ast} = Code.string_to_quoted("if x do :a end")
      refute MutagenEx.Mutators.ElseRemoval.match?(ast)
    end
  end

  describe "site_id format (mutagen.mutators.r3)" do
    test "produces `relative_file:hash:mutator_name`" do
      {:ok, ast} = Code.string_to_quoted("a + b")
      id = Mutators.site_id("lib/example.ex", ast, :arith)
      parts = String.split(id, ":")
      assert length(parts) == 3
      [file, hash, name] = parts
      assert file == "lib/example.ex"
      assert {_int, ""} = Integer.parse(hash)
      assert name == "arith"
    end

    test "ID hash uses :erlang.phash2 of the normalised AST" do
      {:ok, ast} = Code.string_to_quoted("a + b")
      normalised = Mutators.normalize(ast)
      [_f, hash, _n] = "lib/example.ex" |> Mutators.site_id(ast, :arith) |> String.split(":")
      assert String.to_integer(hash) == :erlang.phash2(normalised)
    end
  end

  describe "normalize/1 strips positional metadata (mutagen.decision.content_addressed_ids)" do
    test "strips :line, :column, :end_line, :end_column from every meta keyword" do
      ast =
        {:+, [line: 5, column: 17, end_line: 5, end_column: 22, context: :test],
         [{:x, [line: 5, column: 17], nil}, 1]}

      normalised = Mutators.normalize(ast)

      assert {:+, meta, [{:x, x_meta, nil}, 1]} = normalised
      refute Keyword.has_key?(meta, :line)
      refute Keyword.has_key?(meta, :column)
      refute Keyword.has_key?(meta, :end_line)
      refute Keyword.has_key?(meta, :end_column)
      # Non-positional metadata is preserved per the decision file.
      assert Keyword.get(meta, :context) == :test
      assert x_meta == []
    end

    test "ASTs that differ only in positional metadata hash equal" do
      ast_a = {:+, [line: 5, column: 17], [{:x, [line: 5, column: 17], nil}, 1]}
      ast_b = {:+, [line: 99, column: 1], [{:x, [line: 99, column: 1], nil}, 1]}
      assert Mutators.ast_hash(ast_a) == Mutators.ast_hash(ast_b)
    end
  end

  describe "validate skip reasons (mutagen.mutators.r2)" do
    test "the v1 skip vocabulary covers the three reasons named in the spec" do
      # We don't require every mutator to surface every reason — only that the
      # vocabulary is honoured. WithSwap surfaces :bound_var_used_before_binding;
      # Pipeline surfaces :no_op_shadowed; structural errors surface
      # :structurally_invalid uniformly.
      vocab = [:structurally_invalid, :no_op_shadowed, :bound_var_used_before_binding]

      # Sanity: each mutator's validate/1 either returns :ok or {:skip, atom in vocab}
      # for AST shapes we can throw at it.
      sample_nodes = [
        Code.string_to_quoted!("a + b"),
        Code.string_to_quoted!("a == b"),
        Code.string_to_quoted!("a |> b() |> b()"),
        true,
        0,
        Code.string_to_quoted!("with {:ok, x} <- f(), {:ok, y} <- g(x), do: y"),
        Code.string_to_quoted!("case x do 1 -> :a; 2 -> :b end")
      ]

      for module <- Mutators.all(), node <- sample_nodes do
        result = module.validate(node)

        assert result == :ok or
                 (is_tuple(result) and tuple_size(result) == 2 and
                    elem(result, 0) == :skip and elem(result, 1) in vocab),
               "#{inspect(module)} returned bad validate result #{inspect(result)} for #{inspect(node)}"
      end
    end
  end
end
