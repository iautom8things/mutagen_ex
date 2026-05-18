defmodule MutagenEx.AstDonorEquivalenceTest do
  @moduledoc """
  Donor-equivalence test for `MutagenEx.Ast` per `mutagen.ast.r5`
  (`mutagen.ast.s9`, verification stub `mutagen.ast.v3`).

  The pre-`.25` donor implementations of `alias_to_module/1` and
  `find_module_body/2` are preserved verbatim below as private fixture
  functions. For each AST in the representative corpus, this test
  asserts that the lifted `MutagenEx.Ast` version produces output
  identical to the donor, except for the documented nested-defmodule
  qualification change from `mutagen.ast.r2`. This locks in the safety
  net so a future change to the lifted helpers cannot silently diverge
  from established donor behaviour.

  The donor variants were copy-pasted from:

    * `lib/mutagen_ex/scope_resolver.ex` (pre-`.25` lines ~460-469)
    * `lib/mutagen_ex/mutation_enumerator.ex` (pre-`.25` lines ~446-471)
    * `lib/mutagen_ex/mutation_runner.ex` (pre-`.25` lines ~289-310)

  All three donors had byte-identical `alias_to_module/1`, so we keep
  one copy. The two `find_module_body/2` donors differed only in shape
  (the enumerator version was `defp`, the runner version was `defp`,
  the scope_resolver had a richer `find_defmodule_block/2` that
  returned `body+range+atom` and is intentionally NOT part of the
  lifted surface — see `mutagen.ast` "Out of scope for this subject").
  We keep the simpler enumerator/runner shape since that's what was
  lifted.

  ## Atom-arg compatibility

  Both donor `find_module_body/2` variants accepted a module **atom**
  and matched via `^target_mod`. The lifted version takes a string. To
  exercise true donor equivalence, the test passes the atom to the
  donor and `Atom.to_string/1` of the atom to the lifted version —
  this is exactly how donor callers were rewritten in `.25.2`
  (enumerator passes `Atom.to_string(module)`, runner passes
  `Atom.to_string(target_mod)`).
  """

  use ExUnit.Case, async: true

  alias MutagenEx.Ast

  # ---------------------------------------------------------------------------
  # Pre-`.25` donor implementations (verbatim fixtures)
  # ---------------------------------------------------------------------------
  #
  # DO NOT modify these. They exist to pin the historical behaviour.
  # If a behavioural change is needed, change the lifted version in
  # `MutagenEx.Ast` and EXPECT this test to fail — that failure is the
  # alarm that the change is non-equivalent.

  defp donor_alias_to_module({:__aliases__, _, parts}) when is_list(parts) do
    if Enum.all?(parts, &is_atom/1) do
      Module.concat(parts)
    else
      nil
    end
  end

  defp donor_alias_to_module(mod) when is_atom(mod), do: mod
  defp donor_alias_to_module(_), do: nil

  # The pre-`.25` enumerator/runner `find_module_body/2` — atom-typed
  # target, simple `^target_mod` match. The scope_resolver's richer
  # `find_defmodule_block/2` is intentionally out of scope (it returns
  # body+range+atom and stays in scope_resolver).
  defp donor_find_module_body(ast, target_mod) do
    {_ast, acc} =
      Macro.prewalk(ast, :not_found, fn
        {:defmodule, _meta, [alias_ast, [do: body]]} = node, :not_found ->
          case donor_alias_to_module(alias_ast) do
            ^target_mod -> {node, {:ok, body}}
            _ -> {node, :not_found}
          end

        node, acc ->
          {node, acc}
      end)

    acc
  end

  defp donor_node_line({_form, meta, _args}) when is_list(meta), do: Keyword.get(meta, :line)
  defp donor_node_line(_), do: nil

  # ---------------------------------------------------------------------------
  # Representative AST corpus
  # ---------------------------------------------------------------------------

  # Build 20+ representative AST shapes: quoted modules with simple
  # aliases, nested aliases, attributes, function heads, guards. Mixed
  # in: degenerate shapes that exercise the `nil` / `:not_found`
  # branches.
  defp alias_corpus do
    [
      {:__aliases__, [line: 1], [:Foo]},
      {:__aliases__, [line: 1], [:Foo, :Bar]},
      {:__aliases__, [line: 1], [:Foo, :Bar, :Baz]},
      {:__aliases__, [line: 1], [:Mix, :Tasks, :Mutagen]},
      {:__aliases__, [line: 5, column: 2], [:My, :App, :Module, :With, :Long, :Path]},
      # Dynamic alias (non-atom part) — both should return nil.
      {:__aliases__, [line: 1], [{:meta, [], nil}, :Bar]},
      {:__aliases__, [line: 1], [:Foo, {:meta, [], nil}]},
      # Bare atoms.
      Foo,
      Foo.Bar,
      Some.Very.Long.Module.Name,
      :a_lowercase_atom,
      nil,
      true,
      false,
      # Non-atom, non-alias shapes.
      42,
      "Foo.Bar",
      [],
      [:Foo, :Bar],
      {:not_an_alias, [], [:Foo, :Bar]},
      {:something_else, [line: 3], []},
      {},
      {:a, :b},
      %{a: 1}
    ]
  end

  # Build a corpus of full module ASTs paired with the module atom we
  # expect from the lifted helper (or `:not_found` for negative cases).
  # A fourth element records intentional donor divergence.
  defp module_body_corpus do
    [
      {source_ast("defmodule Foo do\n  def bar, do: :ok\nend\n"), Foo, :found},
      {source_ast("defmodule Foo.Bar do\n  def baz, do: 1\nend\n"), Foo.Bar, :found},
      {source_ast("defmodule A.B.C do\n  @attr :x\n  def f, do: @attr\nend\n"), A.B.C, :found},
      {source_ast(
         "defmodule Guarded do\n  def f(x) when is_integer(x), do: x + 1\n  def f(_), do: 0\nend\n"
       ), Guarded, :found},
      {source_ast(
         "defmodule Multi do\n  defmodule Inner do\n    def inner, do: 1\n  end\n  def outer, do: 2\nend\n"
       ), Multi, :found},
      # r2 now resolves lexical nesting. The lifted helper finds the
      # qualified `Multi.Inner`; the preserved donor still records the
      # legacy AST-alias-only behaviour where unqualified `Inner` matched.
      {source_ast(
         "defmodule Multi do\n  defmodule Inner do\n    def inner, do: 1\n  end\n  def outer, do: 2\nend\n"
       ), Multi.Inner, :found, donor: :not_found},
      {source_ast(
         "defmodule Multi do\n  defmodule Inner do\n    def inner, do: 1\n  end\n  def outer, do: 2\nend\n"
       ), Inner, :not_found, donor: :found},
      {source_ast(
         "defmodule First do\n  def f, do: 1\nend\n\ndefmodule Second do\n  def g, do: 2\nend\n"
       ), Second, :found},
      # Negative cases — module not present in the AST.
      {source_ast("defmodule Foo do\n  def bar, do: :ok\nend\n"), Bar, :not_found},
      {source_ast("defmodule Foo do\n  def bar, do: :ok\nend\n"), Foo.Bar, :not_found},
      {source_ast("defmodule A.B do\n  def f, do: 1\nend\n"), A, :not_found},
      # Degenerate AST inputs.
      {nil, Foo, :not_found},
      {[], Foo, :not_found},
      {42, Foo, :not_found},
      {:not_an_ast, Foo, :not_found},
      # Malformed defmodule shape (missing [do: body] payload).
      {{:defmodule, [], [{:__aliases__, [], [:Foo]}]}, Foo, :not_found}
    ]
  end

  defp node_line_corpus do
    [
      # 3-tuples with various meta shapes
      {:foo, [line: 1], []},
      {:def, [line: 42, column: 3], [{:bar, [line: 42], []}, [do: :ok]]},
      {:+, [line: 99], [{:a, [], nil}, {:b, [], nil}]},
      {:__aliases__, [line: 7], [:Foo]},
      {:something, [], []},
      {:something, [column: 1], []},
      # Edge: meta is nil (some macros)
      {:foo, nil, []},
      # 2-tuples
      {:ok, 1},
      {:error, :reason},
      # Literals
      42,
      :atom,
      nil,
      true,
      "string",
      # Lists
      [],
      [1, 2, 3],
      [:a, :b],
      # Empty tuple
      {},
      # Map
      %{},
      %{a: 1}
    ]
  end

  defp source_ast(src) do
    case Code.string_to_quoted(src, columns: true, token_metadata: true) do
      {:ok, ast} -> ast
      {:error, _} -> nil
    end
  end

  # ---------------------------------------------------------------------------
  # Equivalence tests
  # ---------------------------------------------------------------------------

  describe "alias_to_module/1 donor equivalence (mutagen.ast.s9)" do
    test "lifted version matches donor for every corpus entry" do
      for input <- alias_corpus() do
        donor_out = donor_alias_to_module(input)
        lifted_out = Ast.alias_to_module(input)

        assert lifted_out == donor_out,
               "alias_to_module/1 donor mismatch on input #{inspect(input)}: " <>
                 "donor=#{inspect(donor_out)} lifted=#{inspect(lifted_out)}"
      end
    end

    test "corpus has 20+ shapes (lock guard against silent corpus shrink)" do
      assert length(alias_corpus()) >= 20
    end
  end

  describe "find_module_body/2 donor equivalence (mutagen.ast.s9)" do
    test "lifted version matches donor for every corpus entry" do
      for entry <- module_body_corpus() do
        {ast, target_atom, expected_kind, donor_expected_kind} =
          normalize_module_body_entry(entry)

        donor_out = donor_find_module_body(ast, target_atom)
        lifted_out = Ast.find_module_body(ast, Atom.to_string(target_atom))

        # The two results have the same SHAPE — both either :not_found
        # or {:ok, body} with byte-identical body terms.
        if donor_expected_kind == expected_kind do
          assert kind_of(donor_out) == kind_of(lifted_out),
                 "find_module_body shape mismatch on target=#{inspect(target_atom)}: " <>
                   "donor=#{inspect(donor_out)} lifted=#{inspect(lifted_out)}"

          case {donor_out, lifted_out} do
            {{:ok, donor_body}, {:ok, lifted_body}} ->
              assert donor_body == lifted_body,
                     "find_module_body body mismatch on target=#{inspect(target_atom)}"

            {:not_found, :not_found} ->
              :ok
          end
        end

        # Sanity vs the table's expected kind.
        assert kind_of(lifted_out) == expected_kind
        assert kind_of(donor_out) == donor_expected_kind
      end
    end
  end

  describe "node_line/1 donor equivalence (mutagen.ast.s9)" do
    test "lifted version matches donor for every corpus entry" do
      for input <- node_line_corpus() do
        donor_out = donor_node_line(input)
        lifted_out = Ast.node_line(input)

        assert lifted_out == donor_out,
               "node_line/1 donor mismatch on input #{inspect(input)}: " <>
                 "donor=#{inspect(donor_out)} lifted=#{inspect(lifted_out)}"
      end
    end
  end

  defp kind_of({:ok, _}), do: :found
  defp kind_of(:not_found), do: :not_found

  defp normalize_module_body_entry({ast, target_atom, expected_kind}) do
    {ast, target_atom, expected_kind, expected_kind}
  end

  defp normalize_module_body_entry({ast, target_atom, expected_kind, donor: donor_expected_kind}) do
    {ast, target_atom, expected_kind, donor_expected_kind}
  end
end
