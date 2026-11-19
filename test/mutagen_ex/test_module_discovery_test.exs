defmodule MutagenEx.TestModuleDiscoveryTest do
  use ExUnit.Case, async: true

  alias MutagenEx.TestModuleDiscovery

  @config %{async?: false, group: nil, parameterize: nil}

  @moduletag spec: "mutagen.mutation_pipeline.r25"

  setup %{test: test} do
    dir =
      Path.join(System.tmp_dir!(), "#{__MODULE__}-#{test}-#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  @tag spec: ["mutagen.mutation_pipeline.r10", "mutagen.mutation_pipeline.r25"]
  test "discovers only loaded cases from cited files, including nested cases", %{dir: dir} do
    first = Path.join(dir, "first_test.exs")
    second = Path.join(dir, "second_test.exs")

    File.write!(first, """
    defmodule DiscoverySample do
      def helper, do: :ok

      defmodule ZCase do
        def __ex_unit__, do: :sample
        def __ex_unit__(:config), do: %{async?: true, group: nil, parameterize: nil}
      end

      defmodule ACase do
        def __ex_unit__, do: :sample
        def __ex_unit__(:config), do: %{async?: true, group: nil, parameterize: nil}
      end
    end
    """)

    File.write!(second, """
    defmodule OtherDiscoveryCase do
      def __ex_unit__, do: :sample
      def __ex_unit__(:config), do: %{async?: false, group: nil, parameterize: nil}
    end
    """)

    assert TestModuleDiscovery.discover([first, second]) == []

    Code.compile_file(first)
    Code.compile_file(second)

    assert TestModuleDiscovery.discover([]) == []
    cases = [{DiscoverySample.ZCase, @config}, {DiscoverySample.ACase, @config}]
    assert TestModuleDiscovery.discover([first]) == cases

    assert TestModuleDiscovery.discover([second, first]) == [
             {OtherDiscoveryCase, @config} | cases
           ]
  end

  test "generated case modules appear in module name order", %{dir: dir} do
    file = Path.join(dir, "generated_test.exs")
    names = [:G, :D, :F, :B, :A, :E, :H, :C]

    File.write!(file, """
    for name <- #{inspect(names)} do
      defmodule Module.concat(GeneratedDiscovery, name) do
        def __ex_unit__, do: :sample
        def __ex_unit__(:config), do: %{async?: false, group: nil, parameterize: nil}
      end
    end
    """)

    Code.compile_file(file)

    expected =
      for name <- Enum.sort(names), do: {Module.concat(GeneratedDiscovery, name), @config}

    assert TestModuleDiscovery.discover([file]) == expected
  end

  test "loaded modules fall back to module name order if the source cannot be read or parsed",
       %{dir: dir} do
    file = Path.join(dir, "fallback_test.exs")
    names = for suffix <- [:E, :D, :C, :B, :A], do: Module.concat(DiscoveryFallback, suffix)

    File.write!(
      file,
      Enum.map_join(names, "\n", fn module ->
        """
        defmodule #{inspect(module)} do
          def __ex_unit__, do: :sample
          def __ex_unit__(:config), do: %{async?: false, group: nil, parameterize: nil}
        end
        """
      end)
    )

    Code.compile_file(file)

    assert TestModuleDiscovery.discover([file]) == Enum.map(names, &{&1, @config})
    expected = Enum.map(Enum.sort(names), &{&1, @config})
    File.write!(file, "defmodule Invalid")
    assert TestModuleDiscovery.discover([file]) == expected
    File.rm!(file)
    assert TestModuleDiscovery.discover([file]) == expected
  end
end
