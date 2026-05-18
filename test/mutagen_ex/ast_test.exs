defmodule MutagenEx.AstTest do
  @moduledoc """
  Unit tests for `MutagenEx.Ast` per `mutagen.ast.v1`.

  Covers scenarios `mutagen.ast.s1` through `mutagen.ast.s7`:

    * `s1`-`s3`: `alias_to_module/1` accepts alias tuples, bare atoms, and
      returns `nil` (never raises) for any other shape.
    * `s4`-`s5`: `find_module_body/2` finds the body for a matching
      `defmodule` and returns `:not_found` for a missing target.
    * `s6`-`s7`: `node_line/1` extracts `:line` from 3-tuple meta, returns
      `nil` for literals or 2-tuples.
  """

  use ExUnit.Case, async: true

  alias MutagenEx.Ast

  describe "alias_to_module/1 (mutagen.ast.r1)" do
    test "s1: alias AST tuple with atom parts → Module.concat" do
      ast = {:__aliases__, [line: 1], [:Foo, :Bar]}
      assert Ast.alias_to_module(ast) == Foo.Bar
    end

    test "s1: single-part alias → that module" do
      ast = {:__aliases__, [line: 1], [:Foo]}
      assert Ast.alias_to_module(ast) == Foo
    end

    test "s1: deep nested alias parts" do
      ast = {:__aliases__, [line: 1], [:A, :B, :C, :D]}
      assert Ast.alias_to_module(ast) == A.B.C.D
    end

    test "s2: bare module atom returned unchanged" do
      assert Ast.alias_to_module(Foo.Bar) == Foo.Bar
      assert Ast.alias_to_module(SomeOther.Mod) == SomeOther.Mod
    end

    test "s2: any bare atom (even non-module-shaped) returned unchanged" do
      # alias_to_module/1 is total: an atom comes back as itself. The
      # caller checks for module-ness elsewhere if needed.
      assert Ast.alias_to_module(:not_a_module) == :not_a_module
      assert Ast.alias_to_module(nil) == nil
    end

    test "s3: integer input → nil (no raise)" do
      assert Ast.alias_to_module(42) == nil
    end

    test "s3: list input → nil (no raise)" do
      assert Ast.alias_to_module([:Foo, :Bar]) == nil
    end

    test "s3: string input → nil (no raise)" do
      assert Ast.alias_to_module("Foo.Bar") == nil
    end

    test "s3: 3-tuple that isn't an :__aliases__ form → nil" do
      assert Ast.alias_to_module({:not_an_alias, [], [:Foo, :Bar]}) == nil
    end

    test "s3: :__aliases__ with non-atom parts → nil (dynamic alias)" do
      # E.g. an unquoted alias like Module.concat([something])
      ast = {:__aliases__, [line: 1], [{:meta, [], nil}, :Bar]}
      assert Ast.alias_to_module(ast) == nil
    end

    test "s3: arbitrary tuple → nil" do
      assert Ast.alias_to_module({}) == nil
      assert Ast.alias_to_module({:a, :b}) == nil
    end
  end

  describe "find_module_body/2 (mutagen.ast.r2)" do
    test "s4: matches `defmodule Foo` against the target string \"Foo\"" do
      ast = quoted_module_body("Foo", "def bar, do: :ok")

      assert {:ok, body} = Ast.find_module_body(ast, "Foo")
      # Body should be the def bar AST — exercise a property of it.
      assert match?({:def, _, _}, body)
    end

    test "s4: matches `defmodule Foo.Bar` against \"Foo.Bar\"" do
      ast = quoted_module_body("Foo.Bar", "def baz, do: :ok")

      assert {:ok, body} = Ast.find_module_body(ast, "Foo.Bar")
      assert match?({:def, _, _}, body)
    end

    test "s4: matches against the fully-qualified Elixir.* form too" do
      ast = quoted_module_body("Foo.Bar", "def baz, do: :ok")

      # Callers that hold the atom and prefer to pass its full
      # Atom.to_string/1 form (i.e. "Elixir.Foo.Bar") also match.
      assert {:ok, _body} = Ast.find_module_body(ast, "Elixir.Foo.Bar")
    end

    test "s5: returns :not_found when the target is absent" do
      ast = quoted_module_body("Foo", "def bar, do: :ok")
      assert Ast.find_module_body(ast, "Bar") == :not_found
    end

    test "matches the first defmodule in source order (prewalk)" do
      ast =
        quote do
          defmodule A do
            def a, do: 1
          end

          defmodule B do
            def b, do: 2
          end
        end

      assert {:ok, body_a} = Ast.find_module_body(ast, "A")
      assert {:ok, body_b} = Ast.find_module_body(ast, "B")

      # Different bodies; we got the right one in each case.
      refute body_a == body_b
    end

    test "qualifies nested defmodule aliases with their enclosing module" do
      source = """
      defmodule Outer do
        def outer(x), do: x + 1

        defmodule Inner do
          def inner(x), do: x * 2
        end
      end
      """

      {:ok, ast} = Code.string_to_quoted(source, columns: true, token_metadata: true)

      assert {:ok, outer_body} = Ast.find_module_body(ast, "Outer")
      assert {:ok, inner_body} = Ast.find_module_body(ast, "Outer.Inner")
      assert match?({:__block__, _, _}, outer_body)
      assert match?({:def, _, _}, inner_body)
      assert Ast.find_module_body(ast, "Inner") == :not_found
    end

    test "is total: never raises on a degenerate AST" do
      assert Ast.find_module_body(:not_an_ast_node, "Foo") == :not_found
      assert Ast.find_module_body(42, "Foo") == :not_found
      assert Ast.find_module_body([], "Foo") == :not_found
    end

    test "is total: never raises on a malformed defmodule node" do
      # Missing the [do: body] payload — should not match, should not crash.
      ast = {:defmodule, [], [{:__aliases__, [], [:Foo]}]}
      assert Ast.find_module_body(ast, "Foo") == :not_found
    end

    test "does NOT call String.to_atom on the target string (r8 invariant)" do
      # Pick a string guaranteed not to already be an atom. If
      # find_module_body ever called String.to_atom on the target, the
      # atom would be interned and String.to_existing_atom/1 would then
      # succeed. We assert it still raises afterwards — a precise,
      # concurrency-proof statement of the r8 invariant that does not
      # depend on the global atom counter (the file runs async).
      target = "Mutagen.ProbeNever_#{System.unique_integer([:positive])}_X"
      ast = quoted_module_body("Foo", "def bar, do: :ok")

      # Sanity: the probe atom must not exist before the call, otherwise
      # the assertion below would be vacuous.
      assert_raise ArgumentError, fn -> String.to_existing_atom(target) end

      assert Ast.find_module_body(ast, target) == :not_found

      # If the target atom were minted by the call, this would no longer
      # raise. It must still raise.
      assert_raise ArgumentError, fn -> String.to_existing_atom(target) end
    end
  end

  describe "node_line/1 (mutagen.ast.r3)" do
    test "s6: 3-tuple with :line meta returns the line integer" do
      assert Ast.node_line({:foo, [line: 42], []}) == 42
    end

    test "s6: 3-tuple with :line meta among other keys" do
      assert Ast.node_line({:def, [line: 7, column: 1], []}) == 7
    end

    test "s7: bare literal integer → nil" do
      assert Ast.node_line(42) == nil
    end

    test "s7: bare literal atom → nil" do
      assert Ast.node_line(:foo) == nil
    end

    test "s7: 2-tuple → nil" do
      assert Ast.node_line({:ok, 1}) == nil
    end

    test "s7: list → nil" do
      assert Ast.node_line([1, 2, 3]) == nil
    end

    test "s7: 3-tuple without :line meta → nil" do
      assert Ast.node_line({:foo, [], []}) == nil
      assert Ast.node_line({:foo, [column: 1], []}) == nil
    end

    test "s7: 3-tuple with non-list meta → nil" do
      assert Ast.node_line({:foo, nil, []}) == nil
    end

    test "is total: never raises on weird inputs" do
      assert Ast.node_line(%{}) == nil
      assert Ast.node_line(nil) == nil
      assert Ast.node_line({}) == nil
    end
  end

  # Helper: build an AST for `defmodule <name> do <body_src> end`. We
  # parse the source string so the resulting AST carries realistic
  # metadata, not a synthetic shape — donor parity matters.
  defp quoted_module_body(name, body_src) do
    src = "defmodule #{name} do\n  #{body_src}\nend\n"
    {:ok, ast} = Code.string_to_quoted(src, columns: true, token_metadata: true)
    ast
  end
end
