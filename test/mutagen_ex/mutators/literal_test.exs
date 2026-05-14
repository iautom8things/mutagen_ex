defmodule MutagenEx.Mutators.LiteralTest do
  use ExUnit.Case, async: true

  alias MutagenEx.Mutators.Literal

  test "name is :literal" do
    assert Literal.name() == :literal
  end

  describe "match?/1 — bare values" do
    test "matches booleans and the small integers 0, 1, -1" do
      assert Literal.match?(true)
      assert Literal.match?(false)
      assert Literal.match?(0)
      assert Literal.match?(1)
      assert Literal.match?(-1)
    end

    test "does not match other literals" do
      refute Literal.match?(2)
      refute Literal.match?(:atom)
      refute Literal.match?("string")
      refute Literal.match?([])
    end
  end

  describe "match?/1 — __block__-wrapped values (bw mutagen-wrd.15)" do
    test "matches `{:__block__, meta, [literal]}` for each supported literal" do
      meta = [token: "0", line: 7, column: 12]
      assert Literal.match?({:__block__, meta, [true]})
      assert Literal.match?({:__block__, meta, [false]})
      assert Literal.match?({:__block__, meta, [0]})
      assert Literal.match?({:__block__, meta, [1]})
      assert Literal.match?({:__block__, meta, [-1]})
    end

    test "does not match `__block__` wrappers over unsupported literals" do
      meta = [line: 1]
      refute Literal.match?({:__block__, meta, [2]})
      refute Literal.match?({:__block__, meta, [:atom]})
      refute Literal.match?({:__block__, meta, ["string"]})
    end

    test "does not match `__block__` wrappers over multi-statement bodies" do
      # Multi-statement __block__ (e.g., a function body) has a list of two
      # or more children, not [literal].
      meta = []
      refute Literal.match?({:__block__, meta, [0, 1]})
    end
  end

  describe "mutate/1 — bare values" do
    test "true <-> false" do
      assert Literal.mutate(true) == false
      assert Literal.mutate(false) == true
    end

    test "0 -> 1, 1 -> 0, -1 -> 1" do
      assert Literal.mutate(0) == 1
      assert Literal.mutate(1) == 0
      assert Literal.mutate(-1) == 1
    end

    test "boolean swap is involutive" do
      assert Literal.mutate(Literal.mutate(true)) == true
      assert Literal.mutate(Literal.mutate(false)) == false
    end
  end

  describe "mutate/1 — __block__-wrapped values (bw mutagen-wrd.15)" do
    test "preserves positional meta (`:line`, `:column`) so the enumerator can attribute the swap" do
      # No `:token` in meta — the involutive case. Positional metadata is
      # preserved verbatim so the enumerator's `node_line/1` returns the
      # same line for the swapped node.
      meta = [line: 42, column: 17]

      assert Literal.mutate({:__block__, meta, [0]}) == {:__block__, meta, [1]}
      assert Literal.mutate({:__block__, meta, [1]}) == {:__block__, meta, [0]}
      assert Literal.mutate({:__block__, meta, [-1]}) == {:__block__, meta, [1]}
      assert Literal.mutate({:__block__, meta, [true]}) == {:__block__, meta, [false]}
      assert Literal.mutate({:__block__, meta, [false]}) == {:__block__, meta, [true]}
    end

    test "strips the stale `:token` metadata on swap (so Macro.to_string renders the new value)" do
      # With `token_metadata: true`, the parser records the verbatim
      # source token in `:token`. `Macro.to_string/1` reproduces that
      # token rather than the wrapped value — so a swap that leaves
      # `:token` in place would render the ORIGINAL source, defeating
      # the swap. The mutator strips `:token` so the rendered source
      # reflects the swapped value.
      meta = [token: "true", line: 7, column: 5]
      swapped = Literal.mutate({:__block__, meta, [true]})
      assert {:__block__, new_meta, [false]} = swapped
      refute Keyword.has_key?(new_meta, :token)
      # Positional meta still present.
      assert Keyword.get(new_meta, :line) == 7
      assert Keyword.get(new_meta, :column) == 5
    end

    test "boolean __block__ swap is involutive (token-less meta)" do
      meta = [line: 1, column: 1]
      true_node = {:__block__, meta, [true]}
      false_node = {:__block__, meta, [false]}

      assert Literal.mutate(Literal.mutate(true_node)) == true_node
      assert Literal.mutate(Literal.mutate(false_node)) == false_node
    end

    test "0/1 integer __block__ swap is involutive (token-less meta)" do
      meta = [line: 1, column: 1]
      zero_node = {:__block__, meta, [0]}
      one_node = {:__block__, meta, [1]}

      assert Literal.mutate(Literal.mutate(zero_node)) == zero_node
      assert Literal.mutate(Literal.mutate(one_node)) == one_node
    end
  end

  describe "validate/1" do
    @tag :validate
    test ":ok for bare booleans and integers" do
      assert Literal.validate(true) == :ok
      assert Literal.validate(0) == :ok
      assert Literal.validate(7) == :ok
    end

    @tag :validate
    test ":ok for `__block__`-wrapped booleans and integers" do
      meta = [line: 5]
      assert Literal.validate({:__block__, meta, [true]}) == :ok
      assert Literal.validate({:__block__, meta, [false]}) == :ok
      assert Literal.validate({:__block__, meta, [0]}) == :ok
      assert Literal.validate({:__block__, meta, [1]}) == :ok
      assert Literal.validate({:__block__, meta, [-1]}) == :ok
    end

    @tag :validate
    test ":skip on non-literal input" do
      assert Literal.validate(:atom) == {:skip, :structurally_invalid}
    end

    @tag :validate
    test ":skip on `__block__` wrappers over non-literal values" do
      meta = [line: 1]
      assert Literal.validate({:__block__, meta, [:atom]}) == {:skip, :structurally_invalid}
      assert Literal.validate({:__block__, meta, ["string"]}) == {:skip, :structurally_invalid}
    end
  end

  describe "AST round-trip (mutagen.mutators.r6)" do
    test "Macro.to_string ∘ Code.string_to_quoted preserves the wrapped swap (token-bearing input)" do
      # Build a `__block__`-wrapped `0` the way the parser would (with
      # `token_metadata: true`), mutate it, render to source, re-parse.
      # The parsed AST must contain the SWAPPED value. This is the r6
      # bridge between the AST layer and source-rendering.
      #
      # The `:token` strip in `mutate/1` is load-bearing here: without
      # it `Macro.to_string` would reproduce the original token `"0"`
      # and the round-trip would land back on `0`, not `1`.
      original = {:__block__, [token: "0", line: 3, column: 5], [0]}
      mutated = Literal.mutate(original)

      assert {:__block__, _meta, [1]} = mutated

      source = Macro.to_string(mutated)
      assert source == "1", "swap should render as `1`, got #{inspect(source)}"

      {:ok, reparsed} = Code.string_to_quoted(source, columns: true, token_metadata: true)
      assert reparsed == 1
    end

    test "Macro.to_string ∘ Code.string_to_quoted preserves a boolean wrapped swap" do
      original = {:__block__, [token: "true", line: 3, column: 5], [true]}
      mutated = Literal.mutate(original)

      assert {:__block__, _meta, [false]} = mutated
      source = Macro.to_string(mutated)
      assert source == "false"

      {:ok, reparsed} = Code.string_to_quoted(source, columns: true, token_metadata: true)
      assert reparsed == false
    end
  end
end
