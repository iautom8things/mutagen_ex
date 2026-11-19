defmodule MutagenEx.Mutators.WithSwapTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO, only: [capture_io: 1]

  alias MutagenEx.Mutators.WithSwap

  describe "name/0" do
    test "name is :with_swap" do
      assert WithSwap.name() == :with_swap
    end
  end

  describe "match?/1" do
    test "matches `with` with at least two <- clauses" do
      ast = Code.string_to_quoted!("with {:ok, a} <- f(), {:ok, b} <- g(), do: a + b")
      assert WithSwap.match?(ast)
    end

    test "does not match `with` with only one <- clause" do
      ast = Code.string_to_quoted!("with {:ok, a} <- f(), do: a")
      refute WithSwap.match?(ast)
    end

    test "does not match other forms" do
      refute WithSwap.match?(Code.string_to_quoted!("a + b"))
    end
  end

  describe "mutate/1" do
    test "swaps the first two <- clauses, preserving the do block" do
      ast = Code.string_to_quoted!("with {:ok, a} <- f(), {:ok, b} <- g(), do: a + b")
      mutated = WithSwap.mutate(ast)

      assert {:with, _, [{:<-, _, [first_pat, first_expr]}, {:<-, _, _} | rest]} = mutated

      assert match?({:ok, {:b, _, _}}, first_pat)
      assert match?({:g, _, _}, first_expr)
      # do-block is preserved
      assert [[do: _]] = rest
    end
  end

  describe "validate/1" do
    @tag :validate
    test "{:skip, :bound_var_used_before_binding} when swapped expr references newly-second-bound var (scenario s2)" do
      ast = Code.string_to_quoted!("with {:ok, a} <- f(), {:ok, b} <- g(a), do: a + b")
      swapped = WithSwap.mutate(ast)
      assert WithSwap.validate(swapped) == {:skip, :bound_var_used_before_binding}
    end

    @tag :validate
    test ":ok when the two clauses are independent" do
      ast = Code.string_to_quoted!("with {:ok, a} <- f(), {:ok, b} <- g(), do: a + b")
      swapped = WithSwap.mutate(ast)
      assert WithSwap.validate(swapped) == :ok
    end

    @tag :validate
    test "skips two unconditional bindings even with else" do
      assert validate_swap("with a <- f(), _ <- g(), do: a, else: (_ -> :error)") ==
               {:skip, :insufficient_refutable_patterns}
    end

    @tag :validate
    test "skips when only one of the two swapped matches can fail" do
      for source <- [
            "with a <- f(), :ok <- g(), do: a",
            "with :ok <- f(), a <- g(), do: a",
            "with :ok <- :ok, :ok <- g(), do: :done",
            "with a <- f(), b <- g(), :ok <- h(), do: {a, b}"
          ] do
        assert validate_swap(source) == {:skip, :insufficient_refutable_patterns}, source
      end
    end

    @tag :validate
    test "skips identical failure values even with different patterns or an else that returns its input" do
      for source <- [
            "with :left <- input, :right <- input, do: :done, else: (error -> error)",
            "with :left <- {:error, :bad}, :right <- {:error, :bad}, do: :done"
          ] do
        assert validate_swap(source) == {:skip, :indistinguishable_failures}, source
      end
    end

    @tag :validate
    test "keeps distinct literal failures and treats even repeated calls as opaque" do
      for source <- [
            "with :ok <- {:error, :left}, :ok <- {:error, :right}, do: :done",
            "with :ok <- f(), :ok <- f(), do: :done"
          ] do
        assert validate_swap(source) == :ok, source
      end
    end

    @tag :validate
    test "skips a single wildcard else but keeps an else that uses the failure value" do
      assert validate_swap("with :ok <- f(), :ok <- g(), do: :done, else: (_ -> :error)") ==
               {:skip, :else_ignores_failure}

      assert validate_swap("with :ok <- f(), :ok <- g(), do: :done, else: (error -> error)") ==
               :ok
    end

    @tag :validate
    test "keeps a failure-sensitive else and leaves the third clause in place" do
      {:with, _, [first, second, third, blocks]} =
        ast =
        Code.string_to_quoted!("""
        with {:ok, a} <- first(),
             {:ok, b} <- second(),
             {:ok, c} <- third(a, b) do
          c
        else
          {:error, reason} -> {:rejected, reason}
          _ -> :unknown
        end
        """)

      swapped = WithSwap.mutate(ast)
      assert {:with, _, [^second, ^first, ^third, ^blocks]} = swapped
      assert WithSwap.validate(swapped) == :ok
    end

    @tag :validate
    test "pins and guarded variables can fail and their outer references do not introduce bindings" do
      assert validate_swap("with ^expected <- f(), {:ok, value} <- g(expected), do: value") == :ok

      assert validate_swap(
               "with a when a > limit <- f(), b when is_integer(b) <- g(limit), do: {a, b}"
             ) == :ok
    end

    @tag :validate
    test "keeps swaps that can change which binding is available in the other clause" do
      for {source, inputs, original, swapped} <- [
            {"with ^x <- :old, x <- :new, do: :pass", [x: :old], :pass, :old},
            {"with ^x <- {:ok, :new}, {:ok, x} <- {:ok, :new}, do: :pass", [x: {:ok, :new}],
             :pass, {:ok, :new}},
            {"with %{v: ^x} <- %{v: :old}, {:ok, x} <- {:ok, :new}, do: :pass, else: (_ -> :failed)",
             [x: :old], :pass, :failed},
            {"with :ok <- x, {:ok, x} <- {:ok, :bad}, do: :pass, else: (_ -> :failed)", [x: :ok],
             :pass, :failed},
            {"with {:ok, x} <- a, {:ok, x} <- b, do: x, else: (_ -> :failed)",
             [a: {:ok, 1}, b: {:ok, 2}], 2, 1},
            {"with n when n > x <- b, x <- a, do: :pass", [x: 1, a: 10, b: 2], :pass, 2},
            {"with {:ok, x} <- a, ^x <- b, do: :pass", [x: :old, a: {:ok, :new}, b: :old], :old,
             :pass},
            {"with {:ok, x} <- a, n when n > x <- b, do: :pass", [x: 1, a: {:ok, 10}, b: 2], 2,
             :pass}
          ] do
        assert_swap(source, inputs, :ok, original, swapped)
      end
    end

    @tag :validate
    test "keeps a repeated RHS variable when the swap moves a rebinding before its read" do
      assert_swap(
        "with :ok <- x, {:ok, x} <- x, do: :pass",
        [x: {:ok, :ok}],
        :ok,
        {:ok, :ok},
        :pass
      )
    end

    @tag :validate
    test "a wildcard else keeps swaps whose moved-first pattern reads a later binding" do
      for {source, inputs, failure} <- [
            {"with {:ok, x} <- a, ^x <- b, do: :pass, else: (_ -> :failed)",
             [x: :old, a: {:ok, :new}, b: :old], :failed},
            {"with {:ok, n} <- a, <<_v::binary-size(n)>> <- b, do: :pass, else: (_ -> :f)",
             [n: 1, a: {:ok, 2}, b: <<1>>], :f},
            {"with {:ok, x} <- a, n when n > x <- b, do: :pass, else: (_ -> :f)",
             [x: 1, a: {:ok, 10}, b: 2], :f}
          ] do
        assert_swap(source, inputs, :ok, failure, :pass)
      end
    end

    @tag :validate
    test "keeps lexical introspection even with fresh bindings and a wildcard else" do
      for {source, inputs, failure} <- [
            {"with x <- :one, true <- Keyword.has_key?(binding(), :x), do: :pass", [], false},
            {"with {:ok, x} <- a, true <- Keyword.has_key?(binding(), :x), do: :pass, else: (_ -> :failed)",
             [a: {:ok, :one}], :failed},
            {"with x <- :one, true <- Macro.Env.has_var?(__ENV__, {:x, nil}), do: :pass", [],
             false},
            {"with x <- :one, true <- Keyword.has_key?(Kernel.binding(), :x), do: :pass", [],
             false}
          ] do
        assert_swap(source, inputs, :ok, :pass, failure)
      end
    end

    @tag :validate
    test "keeps no-argument dbg calls that inspect the binding" do
      capture_io(fn ->
        for call <- ["dbg()", "Kernel.dbg()"] do
          assert_swap("with x <- :one, [_ | _] <- #{call}, do: x", [], :ok, :one, [])
        end
      end)
    end

    @tag :validate
    test "the RHS name check can mistake nested binders or quoted data for a read" do
      for {source, swapped} <- [
            {"with {:ok, x} <- a, :ok <- (fn x -> x end).(:b), do: x", :b},
            {"with {:ok, x} <- a, :ok <- (x = :b), do: x", :b},
            {"with {:ok, x} <- a, :ok <- (quote do: x), do: x", {:x, [], Elixir}},
            {"with {:ok, x} <- a, :ok <- Macro.to_string(quote unquote: false, do: unquote(x)), do: x",
             "unquote(x)"},
            {"with {:ok, x} <- a, :ok <- (x = :b; x), do: x", :b},
            {"with {:ok, x} <- a, :ok <- (case :b do x -> x end), do: :pass", :b}
          ] do
        assert_swap(source, [a: :a], {:skip, :bound_var_used_before_binding}, :a, swapped)
      end
    end

    @tag :validate
    test "module attributes introduce neither reads nor bindings" do
      assert_swap(
        "with {:ok, limit} <- a, true <- b < @limit, do: limit",
        [a: :err, b: 10],
        :ok,
        :err,
        false,
        &run_with_attributes/2
      )

      assert_swap(
        "with @expected <- a, :ok <- (if expected, do: :ok, else: :no), do: :pass",
        [a: :bad, expected: false],
        :ok,
        :bad,
        :no,
        &run_with_attributes/2
      )
    end

    @tag :validate
    test "string and sigil interpolation do not read a variable named binary" do
      for literal <- [~S("#{b}"), ~S(~s|#{b}|)] do
        assert_swap(
          "with {:ok, binary} <- a, :ok <- String.to_atom(#{literal}), do: binary",
          [a: :err, b: "bad"],
          :ok,
          :err,
          :bad
        )
      end

      assert_unbound_swap(
        ~S|with {:ok, binary} <- a, :ok <- String.to_atom("#{binary}"), do: :pass|,
        [a: {:ok, "ok"}],
        {:skip, :bound_var_used_before_binding},
        :pass
      )
    end

    @tag :validate
    test "reads in unquote and on the right side of a match can use a now-later binding" do
      for {source, original} <- [
            {"with {:ok, x} <- a, :ok <- (quote do: unquote(x)), do: x", :pass},
            {"with {:ok, x} <- a, :ok <- (y = x), do: x", :pass},
            {"with {:ok, _x} <- a, :ok <- hd([_x]), do: :pass", :pass}
          ] do
        inputs = [a: {:ok, :pass}]
        assert_unbound_swap(source, inputs, {:skip, :bound_var_used_before_binding}, original)
      end
    end

    @tag :validate
    test "reads in a binary size can use a preceding segment or an enclosing binding" do
      for size <- ["n", "^n"] do
        source = "with {:ok, n} <- a, <<_v::size(#{size})>> <- b, do: :pass"
        assert_swap(source, [n: 4, a: {:ok, 8}, b: <<1>>], :ok, :pass, <<1>>)
        assert_unbound_swap(source, [a: {:ok, 8}, b: <<1>>], :ok, :pass)
      end

      assert_swap(
        "with n <- count, :ok <- (fn <<n, _v::size(n)>> -> :ok end).(b), do: n",
        [b: <<8, 42>>, count: 8],
        {:skip, :bound_var_used_before_binding},
        8,
        8
      )

      assert_swap(
        "with <<v::size(n)>> <- b, n <- count, do: {v, n}",
        [n: 8, b: <<42>>, count: 4],
        :ok,
        {42, 4},
        <<42>>
      )

      assert_swap(
        "with <<n, v::size(^n)>> <- b, n <- count, do: {v, n}",
        [n: 4, b: <<0, 10::4>>, count: 8],
        :ok,
        {10, 8},
        <<0, 10::4>>
      )
    end

    @tag :validate
    test "defers missing pins and guard bindings to the compiler" do
      for {source, inputs, original} <- [
            {"with {:ok, key} <- a, %{^key => v} <- b, do: v", [a: {:ok, :k}, b: %{k: :v}], :v},
            {"with {:ok, x} <- a, ^x <- b, do: :pass", [a: {:ok, :a}, b: :a], :pass},
            {"with {:ok, x} <- a, n when n > x <- b, do: :pass", [a: {:ok, 1}, b: 2], :pass}
          ] do
        assert_unbound_swap(source, inputs, :ok, original)
      end
    end

    @tag :validate
    test "compares matching literals with the production parser's token metadata" do
      for {left, right, returned} <- [
            {"%{a: 1}", "%{a: 1}", %{a: 1}},
            {"%{a: 1, b: %{c: 2}}", "%{b: %{c: 2}, a: 1}", %{a: 1, b: %{c: 2}}},
            {"({\n  :a,\n  :b, :c\n})", "{:a, :b, :c}", {:a, :b, :c}},
            {"Foo.Bar", "Foo.Bar", Foo.Bar},
            {"<<1, 2>>", "<<1, 2>>", <<1, 2>>}
          ] do
        assert_swap(
          "with :left <- #{left}, :right <- #{right}, do: :pass",
          [],
          {:skip, :indistinguishable_failures},
          returned,
          returned
        )
      end

      assert_swap(
        "with %{a: 1} <- %{a: 1}, :ok <- b, do: :pass",
        [b: :b],
        {:skip, :insufficient_refutable_patterns},
        :b,
        :b
      )
    end

    @tag :validate
    test "{:skip, :structurally_invalid} on non-with input" do
      assert WithSwap.validate(42) == {:skip, :structurally_invalid}
    end
  end

  defp validate_swap(source), do: source |> parse() |> WithSwap.mutate() |> WithSwap.validate()

  defp parse(source), do: Code.string_to_quoted!(source, columns: true, token_metadata: true)

  defp assert_swap(source, inputs, decision, original, swapped, runner \\ &run/2) do
    ast = parse(source)
    mutant = WithSwap.mutate(ast)
    assert {source, WithSwap.validate(mutant)} == {source, decision}
    assert {source, runner.(ast, inputs)} == {source, original}
    assert {source, runner.(mutant, inputs)} == {source, swapped}
  end

  defp assert_unbound_swap(source, inputs, decision, original) do
    ast = parse(source)
    mutant = WithSwap.mutate(ast)
    assert {source, WithSwap.validate(mutant)} == {source, decision}
    assert {source, run(ast, inputs)} == {source, original}

    {result, diagnostics} =
      Code.with_diagnostics(fn ->
        try do
          Code.eval_quoted(mutant, inputs)
        rescue
          error in CompileError -> error
        end
      end)

    assert %CompileError{} = result
    assert Enum.any?(diagnostics, &String.contains?(&1.message, "undefined variable")), source
  end

  defp run(ast, inputs) do
    {{value, _bindings}, _diagnostics} =
      Code.with_diagnostics(fn -> Code.eval_quoted(ast, inputs) end)

    value
  end

  defp run_with_attributes(ast, inputs) do
    module = Module.concat(__MODULE__, "Attributes#{System.unique_integer([:positive])}")
    params = for {name, _} <- inputs, do: Macro.var(name, nil)

    body =
      quote do
        @limit 5
        @expected :ok

        def run(unquote_splicing(params)), do: unquote(ast)
      end

    try do
      {{:module, ^module, _, _}, _} =
        Code.with_diagnostics(fn -> Module.create(module, body, Macro.Env.location(__ENV__)) end)

      apply(module, :run, Keyword.values(inputs))
    after
      :code.delete(module)
      :code.purge(module)
    end
  end
end
