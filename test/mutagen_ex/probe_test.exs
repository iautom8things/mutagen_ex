defmodule MutagenEx.ProbeTest do
  use ExUnit.Case, async: false

  alias MutagenEx.{AstCache, MutationEnumerator, MutationRunner, Probe}
  alias MutagenEx.ScopeResolver.Scope

  @fixtures Path.expand("../fixtures/branch_coverage", __DIR__)

  @tag :tmp_dir
  @tag spec: "mutagen.coverage.r15"
  test "instrumenting all wrappable fixture sites preserves the suite and separates live sites from cold sites",
       %{tmp_dir: dir} do
    module = ProbeShapeFixture
    source = read_fixture("example.ex", module)
    {file, ast} = compile_fixture(dir, "shape.ex", source)
    cache = %{file => {ast, source}}
    scope = %Scope{file: file, module: module, line_range: 1..1_000}

    %{sites: sites} =
      MutationEnumerator.enumerate(cache, [scope], %{}, planned: %{file => [1..1_000]})

    sites = Enum.filter(sites, & &1.runtime?)

    exercises =
      Macro.prewalk(Code.string_to_quoted!(read_fixture("example_test.exs", module)), [], fn
        {:test, _, [_, [do: body]]} = node, found -> {node, [body | found]}
        node, found -> {node, found}
      end)
      |> elem(1)

    run = fn ->
      Enum.map(exercises, fn body ->
        {value, _} =
          Code.eval_quoted(
            quote(
              do:
                (
                  import ExUnit.Assertions
                  unquote(body)
                )
            )
          )

        value
      end)
    end

    expected = run.()
    checksum = apply(module, :__info__, [:md5])

    assert {:ok, %{evidence: evidence}} =
             Probe.run(sites, %{cache: cache}, fn ->
               assert run.() == expected
               send(self(), :suite_ran)
               {:ok, 1}
             end)

    assert_received :suite_ran
    refute_received :suite_ran
    assert apply(module, :__info__, [:md5]) == checksum

    for name <-
          ~w(guard_live multi_live pipe head_list_live head_map_live head_tuple_live head_pipe_live
                    tup one_live partial arm arm_tuple cond_tuple branch_tuple branch_tuple_lit
                    branch_tuple_multi with_else with_else_taken nested_branch) do
      assert Enum.any?(sites, fn site ->
               site.function =~ ".#{name}/" and evidence[site.id] == {:probe, :executed}
             end),
             "no probe hit for #{name}"
    end

    for name <-
          ~w(multi_cold one_cold cold_tail head_list_cold head_map_cold head_tuple_cold head_pipe_cold) do
      assert Enum.any?(sites, fn site ->
               site.function =~ ".#{name}/" and evidence[site.id] == {:probe, :uncovered}
             end),
             "no cold probe for #{name}"

      refute Enum.any?(sites, fn site ->
               site.function =~ ".#{name}/" and evidence[site.id] == {:probe, :executed}
             end)
    end

    assert Enum.any?(sites, fn site ->
             site.function =~ ".guard_cold/" and
               evidence[site.id] == {:could_not_tell, :probe_unwrappable}
           end)

    assert Enum.any?(sites, fn site ->
             site.function =~ ".guard_cold/" and site.mutator == :arith and
               evidence[site.id] == {:probe, :uncovered}
           end)

    assert {:ok, %{evidence: discarded}} =
             Probe.run(sites, %{cache: cache}, fn ->
               assert run.() == expected
               :failed
             end)

    for {id, {:probe, _}} <- evidence do
      assert discarded[id] == {:could_not_tell, :probe_suite_failed}
    end

    assert apply(module, :__info__, [:md5]) == checksum
  end

  @tag :tmp_dir
  @tag spec: "mutagen.coverage.r15"
  test "restores a failed compile and runs the usable probe files together", %{tmp_dir: dir} do
    {good, before_good} =
      compile_fixture(
        dir,
        "good.ex",
        "defmodule ProbeGreenFixture do\n def ok, do: :original\nend"
      )

    {bad, before_bad} =
      compile_fixture(
        dir,
        "bad.ex",
        "defmodule ProbeBrokenFixture do\n def ok, do: :original\nend"
      )

    modified =
      quote do
        defmodule ProbeGreenFixture do
          def ok, do: :probed
        end
      end

    broken =
      quote do
        defmodule ProbeBrokenFixture do
          def ok, do: undefined_at_compile_time()
        end
      end

    assert {:ok, loaded, :ok} =
             MutationRunner.with_probe_files(
               [{good, before_good, modified, []}, {bad, before_bad, broken, []}],
               fn ->
                 assert apply(ProbeGreenFixture, :ok, []) == :probed
                 assert apply(ProbeBrokenFixture, :ok, []) == :original
                 :ok
               end
             )

    assert loaded == MapSet.new([good])
    assert apply(ProbeGreenFixture, :ok, []) == :original
    assert apply(ProbeBrokenFixture, :ok, []) == :original
  end

  @tag :e2e_slow
  @tag spec: "mutagen.coverage.r15"
  test "all placements compile across the library and lane sources in a separate VM" do
    script = ~S"""
    alias MutagenEx.{AstCache, MutationEnumerator, Probe, ScopeResolver}
    Mix.start()
    Code.put_compiler_option(:ignore_module_conflict, true)
    files = Path.wildcard("lib/**/*.ex") ++ Path.wildcard("test/fixtures/lane_project/lib/**/*.ex")

    prepared = for file <- files do
      {:ok, {ast, source}} = AstCache.parse(file, File.read!(file))
      scopes = ScopeResolver.file_scopes(file, ast)
      lines = %{file => [1..(length(:binary.matches(source, "\n")) + 1)]}
      %{sites: sites} = MutationEnumerator.enumerate(%{file => {ast, source}}, scopes, %{},
        planned: lines, source: false)
      {probed, placed} = Probe.instrument(ast, Enum.with_index(Enum.filter(sites, & &1.runtime?), 1), 1)
      {file, probed, length(placed)}
    end

    for {file, ast, count} <- prepared, count > 0, do: Code.compile_quoted(ast, file)
    IO.puts("Compiled #{Enum.sum_by(prepared, &elem(&1, 2))} probe placements")
    """

    {output, status} =
      System.cmd("elixir", ["-pa", Mix.Project.compile_path(), "-e", script],
        stderr_to_stdout: true,
        env: [{"ERL_AFLAGS", "+S 2:2 +SDcpu 1 +SDio 2"}]
      )

    assert status == 0, output
    assert output =~ ~r/Compiled [1-9][0-9]+ probe placements/
  end

  defp compile_fixture(dir, name, source) do
    file = Path.join(dir, name)
    File.write!(file, source)
    assert Code.prepend_path(dir)
    on_exit(fn -> Code.delete_path(dir) end)

    assert {:ok, _, _} =
             Kernel.ParallelCompiler.compile_to_path([file], dir, return_diagnostics: true)

    assert {:ok, {ast, ^source}} = AstCache.parse(file, source)
    {file, ast}
  end

  defp read_fixture(name, module) do
    @fixtures
    |> Path.join(name)
    |> File.read!()
    |> String.replace("ChangedRunFixture.Example", inspect(module))
  end
end
