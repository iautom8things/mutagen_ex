defmodule MutagenEx.PlannedSitesTest do
  use ExUnit.Case, async: true

  alias MutagenEx.Ast
  alias MutagenEx.MutationEnumerator
  alias MutagenEx.Mutators
  alias MutagenEx.ScopeResolver.Scope

  @file_path "lib/sample.ex"
  @group {Sample, :target, 1}

  @tag spec: ["mutagen.mutation_enumeration.r12", "mutagen.mutators.r12"]
  test "a fingerprint hashes normalized clauses in walk order under their ID group key" do
    ast =
      module_source("""
      @default true
      def target(0), do: 1
      field :enabled, :boolean, default: true
      def target(x), do: x + 1
      field :enabled, :boolean, default: false
      """)
      |> parse()

    assert [{Sample, _, {:__block__, _, [attribute, first, field1, second, field2]}}] =
             Ast.module_blocks(ast)

    assert MutationEnumerator.group_fingerprints(ast) == %{
             @group => digest([first, second]),
             {Sample, {:@, :default}} => digest([attribute]),
             {Sample, {:field, :enabled}} => digest([field1, field2])
           }

    identity = {@group, Mutators.identity_node(first), 0}

    assert Mutators.site_id(@file_path, identity, :arith) ==
             "#{@file_path}:#{Mutators.identity_hash(identity)}:arith"

    for entry <- ast |> plan_ast() |> planned_entries() do
      assert entry.fingerprint ==
               Map.fetch!(MutationEnumerator.group_fingerprints(ast), entry.group_key)
    end
  end

  @tag spec: "mutagen.mutation_enumeration.r12"
  test "equal fingerprints preserve ID-to-path mappings across generated edits outside the group" do
    :rand.seed(:exsss, {24, 980, 7})

    for _ <- 1..60 do
      clauses =
        for arg <- 1..:rand.uniform(5) do
          body = for _ <- 1..:rand.uniform(6), do: Enum.random(["x + 1", "x - 0", "{x, 1, 1}"])

          """
          def target(x) when x == #{arg} do
            consume(#{Enum.join(body, ", ")})
          end
          """
        end

      other = "def other(x), do: x + 1"
      original = module_source(Enum.join([other | clauses], "\n"))
      [first | rest] = clauses

      moved =
        Enum.join([first, "# a new comment", "", "def other(x), do: x * 3" | rest], "\n")
        |> module_source()

      expected = target_sites(original)
      assert expected != []
      expected_fingerprint = fingerprint(original)

      for length <- [34, 55, 98] do
        formatted = format(original, length)
        assert fingerprint(formatted) == expected_fingerprint
        assert id_paths(target_sites(formatted)) == id_paths(expected)

        formatted_move = format(moved, length)
        assert fingerprint(formatted_move) == expected_fingerprint
        moved_sites = target_sites(formatted_move)
        refute id_paths(moved_sites) == id_paths(expected)

        assert clause_paths(moved_sites, [0 | Enum.drop(Enum.to_list(0..length(clauses)), 2)]) ==
                 clause_paths(expected, Enum.to_list(1..length(clauses)))
      end
    end
  end

  @tag spec: "mutagen.mutation_enumeration.r12"
  test "the four transfer shapes change the group fingerprint" do
    body = "def target(x) do\n  x + 1 # original\n  x * 2\nend"
    clause = "def target(x), do: x + 1 # original"

    for {before, after_edit} <- [
          {body, String.replace(body, "  x + 1", "  x + 1 # transferred\n  x + 1")},
          {clause, "def target(x) when is_integer(x), do: x + 1 # transferred\n" <> clause},
          {body, "def target(x) do\n  x * 2\n  x + 1 # transferred\nend"}
        ] do
      before = module_source(before)
      after_edit = module_source(after_edit)
      refute fingerprint(before) == fingerprint(after_edit)

      old = Enum.find(target_sites(before), &match?({:+, _, _}, &1.original_ast))
      assert transferred = Enum.find(target_sites(after_edit), &(&1.id == old.id))
      assert Enum.at(String.split(after_edit, "\n"), transferred.line - 1) =~ "# transferred"
    end

    refute fingerprint(module_source("def target(x), do: {x, 1, 1}")) ==
             fingerprint(module_source("def target(x), do: {1, x, 1}"))
  end

  @tag spec: "mutagen.mutation_enumeration.r13"
  test "planning uses span overlap, ignores coverage, and preserves validator skips" do
    source = """
    defmodule Sample do
      def unchanged(x), do: x + 1
      def multiline(x) do
        x +
          1
      end

      def skipped do
        with {:ok, a} <- f(), {:ok, b} <- g(a) do
          a + b
        end
      end
    end
    """

    ast = parse(source)
    scope = scope(@file_path, Sample, 1..13)
    mutators = [Mutators.Arith, Mutators.WithSwap]
    coverage = %{@file_path => MapSet.new([2])}
    changes = %{@file_path => [5..5, 11..11], "lib/other.ex" => [1..13]}
    cache = %{@file_path => ast}

    assert %{sites: [site], skipped: [skip], warnings: []} =
             MutationEnumerator.enumerate(cache, [scope], coverage,
               planned: changes,
               mutators: mutators
             )

    assert %{line: 4, end_line: 5, group_key: {Sample, :multiline, 1}, runtime?: true} = site
    assert is_binary(site.fingerprint)

    assert %{
             reason: :bound_var_used_before_binding,
             line: 9,
             end_line: 11,
             group_key: {Sample, :skipped, 0},
             runtime?: true
           } = skip

    assert is_binary(skip.fingerprint)

    assert %{sites: [%MutationEnumerator.Site{line: 2}], skipped: []} =
             MutationEnumerator.enumerate(cache, [scope], coverage, mutators: mutators)

    assert %{sites: [], skipped: []} =
             MutationEnumerator.enumerate(cache, [scope], coverage,
               planned: Map.delete(changes, @file_path)
             )
  end

  @tag spec: "mutagen.mutation_enumeration.r14"
  test "only named def and defp sites outside quotes are runtime sites" do
    for {body, expected} <- [
          {"def target(x), do: x + 1", true},
          {"defp target(x), do: x + 1", true},
          {"schema \"things\" do\n  field :enabled, :boolean, default: true\nend", false},
          {"get \"/things\", Things, enabled: true", false},
          {"@enabled true", false},
          {"use Things, enabled: true", false},
          {"defmacro target(x), do: x + 1", false},
          {"defmacrop target(x), do: x + 1", false},
          {"quote do: (def target(x), do: x + 1)", false},
          {"def target(x), do: quote(do: x + 1)", false},
          {"defguard target(x) when x > 0", false},
          {"defguardp target(x) when x > 0", false},
          {"def unquote(n)(), do: 1", false}
        ] do
      entries = body |> module_source() |> plan() |> planned_entries()
      assert entries != [], body
      assert Enum.all?(entries, &(&1.runtime? == expected)), body
    end
  end

  @tag spec: "mutagen.mutation_enumeration.r15"
  test "whitespace, comments, formatter reflow, and moves leave no planned sites in scope" do
    source = """
    defmodule Sample do
      def target(x), do: call_some_function(x + 1, x + 2, x + 3)
      def other(x), do: x * 1
    end
    """

    for {revision, changed_lines} <- [
          {String.replace(source, "x + 1", "x  +  1"), [2..2]},
          {String.replace(source, "x * 1", "x * 1 # another comment"), [3..3]},
          {format(source, 28), [2..8]},
          {module_source("""
           def other(x), do: x * 1
           def target(x), do: call_some_function(x + 1, x + 2, x + 3)
           """), [3..3]}
        ] do
      assert revision != source
      entries = revision |> plan(changed_lines) |> planned_entries()
      assert entries != []
      assert MutationEnumerator.fingerprint_scope(entries, source) == {[], []}
    end
  end

  @tag spec: "mutagen.mutation_enumeration.r15"
  test "scope keeps changed groups on changed lines, new and renamed groups, and missing base files" do
    base = """
    defmodule Sample do
      def target(x) do
        one(x + 1)
        two(x * 1)
      end
      def other(x), do: x + 1
    end
    """

    edited = String.replace(base, "one(x + 1)", "one(x - 1)")
    changed = edited |> plan([3..3, 6..6]) |> planned_entries()
    assert Enum.any?(changed, &(&1.function == "Sample.other/1"))
    assert {in_scope, []} = MutationEnumerator.fingerprint_scope(changed, base)
    assert in_scope != []
    assert Enum.all?(in_scope, &(&1.line == 3 and &1.group_key == @group))

    added = String.replace(base, "  def other", "  def new(x), do: x * 1\n  def other")
    new_group = added |> plan([6..6]) |> planned_entries()
    assert new_group != []
    assert Enum.all?(new_group, &(&1.group_key == {Sample, :new, 1}))
    assert MutationEnumerator.fingerprint_scope(new_group, base) == {new_group, []}

    renamed = String.replace(base, "def target", "def renamed")
    renamed_group = renamed |> plan([3..4]) |> planned_entries()
    assert renamed_group != []
    assert Enum.all?(renamed_group, &(&1.group_key == {Sample, :renamed, 1}))
    assert MutationEnumerator.fingerprint_scope(renamed_group, base) == {renamed_group, []}

    assert MutationEnumerator.fingerprint_scope(changed, :absent) == {changed, []}

    assert {^changed, [{:base_parse_error, _location}]} =
             MutationEnumerator.fingerprint_scope(changed, "defmodule Sample do\n")

    assert MutationEnumerator.fingerprint_scope(changed, <<255>>) ==
             {changed, [{:base_parse_error, :invalid_encoding}]}

    renamed_file =
      edited |> parse() |> plan_ast([3..3, 6..6], "lib/renamed.ex") |> planned_entries()

    assert renamed_file != []
    assert MutationEnumerator.fingerprint_scope(renamed_file, edited) == {[], []}
  end

  @tag spec: "mutagen.mutation_enumeration.r16"
  test "planned runtime IDs partition exactly once over every Elixir fixture source" do
    files =
      Path.wildcard("test/fixtures/**/*.{ex,exs}")
      |> Enum.reject(&Enum.any?(Path.split(&1), fn part -> part in ["deps", "_build"] end))

    assert files != []

    for file <- files do
      source = File.read!(file)
      lines = 1..length(String.split(source, "\n"))
      ast = parse(source)
      result = plan_ast(ast, [lines], file)

      planned = Enum.filter(planned_entries(result), & &1.runtime?)
      planned_ids = Enum.map(planned, &id/1)
      assert MapSet.size(MapSet.new(planned_ids)) == length(planned_ids), file

      {executed, absent} =
        result.sites
        |> Enum.filter(& &1.runtime?)
        |> Enum.with_index()
        |> Enum.split_with(fn {_site, i} -> rem(i, 5) != 4 end)

      output =
        Enum.reduce(executed, %{results: [], compile_errors: [], skipped: result.skipped}, fn
          {site, i}, output when rem(i, 5) == 3 ->
            update_in(output.compile_errors, &[%{id: site.id} | &1])

          {site, i}, output ->
            status = Enum.at([:killed, :survived, :error], rem(i, 5))
            update_in(output.results, &[%{id: site.id, status: status} | &1])
        end)

      parts = MutationEnumerator.partition_planned_runtime_sites(planned, output)
      part_ids = Enum.flat_map(Map.values(parts), &Enum.map(&1, fn entry -> id(entry) end))
      assert Enum.sort(planned_ids) == Enum.sort(part_ids), file

      assert Enum.map(parts.uncovered_candidate, &id/1) ==
               Enum.map(absent, fn {site, _} -> site.id end),
             file

      assert Enum.map(parts.not_run, &id/1) ==
               for(%{id: id, status: :error} <- Enum.reverse(output.results), do: id)
    end
  end

  @tag spec: "mutagen.mutation_enumeration.r16"
  test "each evaluator outcome takes its planned ID out of the uncovered candidates" do
    plan = module_source("def target(xs), do: Enum.map(xs, &(&1 + 1 + 1 + 1))") |> plan()
    assert [skip] = plan.skipped
    assert [killed, timeout, survivor, failed_compile, error, missing | _] = plan.sites

    output = %{
      results: [
        %{id: killed.id, status: :killed},
        %{id: timeout.id, status: :timeout},
        %{id: survivor.id, status: :survived},
        %{id: error.id, status: :error}
      ],
      skipped: [%{site_id: skip.site_id}],
      compile_errors: [%{id: failed_compile.id}]
    }

    partitions =
      MutationEnumerator.partition_planned_runtime_sites(
        [killed, timeout, survivor, failed_compile, error, missing, skip],
        output
      )

    assert partitions == %{
             evaluated: [killed, timeout, survivor, failed_compile, skip],
             uncovered_candidate: [missing],
             not_run: [error]
           }
  end

  defp module_source(body), do: "defmodule Sample do\n" <> body <> "\nend\n"
  defp parse(source), do: Code.string_to_quoted!(source, columns: true, token_metadata: true)

  defp format(source, length) do
    source |> Code.format_string!(line_length: length) |> IO.iodata_to_binary()
  end

  defp digest(clauses),
    do: clauses |> Enum.map(&Mutators.identity_node/1) |> Mutators.identity_hash()

  defp fingerprint(source),
    do: source |> parse() |> MutationEnumerator.group_fingerprints() |> Map.fetch!(@group)

  defp target_sites(source),
    do: source |> plan() |> Map.fetch!(:sites) |> Enum.filter(&(&1.group_key == @group))

  defp id_paths(sites), do: Map.new(sites, &{&1.id, &1.path})

  defp clause_paths(sites, clause_indexes) do
    Map.new(sites, fn site ->
      [{:arg, 1}, {:elem, 0}, :right, {:arg, index} | path] = site.path
      {site.id, {Enum.find_index(clause_indexes, &(&1 == index)), path}}
    end)
  end

  defp plan(source, changes \\ [1..1000]), do: source |> parse() |> plan_ast(changes)

  defp plan_ast(ast, changes \\ [1..1000], file \\ @file_path) do
    %{last: last} = List.last(changes)

    scopes =
      ast
      |> Ast.module_blocks()
      |> Enum.map(fn {module, _node, _body} -> scope(file, module, 1..max(last, 1000)) end)

    MutationEnumerator.enumerate(%{file => ast}, scopes, %{}, planned: %{file => changes})
  end

  defp scope(file, module, lines), do: %Scope{file: file, module: module, line_range: lines}
  defp planned_entries(result), do: result.sites ++ result.skipped
  defp id(%{id: id}), do: id
  defp id(%{site_id: id}), do: id
end
