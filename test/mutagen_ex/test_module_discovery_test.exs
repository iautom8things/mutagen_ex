defmodule MutagenEx.TestModuleDiscoveryTest do
  use ExUnit.Case, async: true

  alias MutagenEx.TestModuleDiscovery

  @config %{async?: false, group: nil, parameterize: nil}

  @tag spec: ["mutagen.mutation_pipeline.r10", "mutagen.mutation_pipeline.r25"]
  test "discovers only loaded cases from cited files, including nested cases", %{test: test} do
    dir =
      Path.join(System.tmp_dir!(), "#{__MODULE__}-#{test}-#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    first = Path.join(dir, "first_test.exs")
    second = Path.join(dir, "second_test.exs")

    File.write!(first, """
    defmodule DiscoverySample do
      def helper, do: :ok

      defmodule Case do
        def __ex_unit__, do: :sample
      end
    end
    """)

    File.write!(second, """
    defmodule OtherDiscoveryCase do
      def __ex_unit__, do: :sample
    end
    """)

    assert TestModuleDiscovery.discover([first, second]) == []

    Code.compile_file(first)
    Code.compile_file(second)

    assert TestModuleDiscovery.discover([]) == []
    assert TestModuleDiscovery.discover([first]) == [{DiscoverySample.Case, @config}]

    assert TestModuleDiscovery.discover([second, first]) == [
             {OtherDiscoveryCase, @config},
             {DiscoverySample.Case, @config}
           ]
  end
end
