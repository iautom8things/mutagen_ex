defmodule MutagenEx.Test.SuiteTest do
  use ExUnit.Case, async: true

  alias MutagenEx.Test.Suite
  alias MutagenEx.TestSelector.TestFilter

  defmodule RaisingExUnit do
    @moduledoc false
    def run, do: raise("database password: hunter2 unavailable")
  end

  @tag spec: ["mutagen.coverage.r11", "mutagen.mutation_pipeline.r21"]
  test "a pass that executes no test is rejected with its rendered filters" do
    filter = %TestFilter{
      files: ["test/a_test.exs"],
      include: [{:location, {"test/a_test.exs", 8}}],
      exclude: [:test, database: :off]
    }

    ran_one = %{total: 2, failures: 0, excluded: 1, skipped: 0}
    assert :ok = Suite.require_tests(ran_one, filter, :mutation)

    ran_none = %{total: 2, failures: 0, excluded: 1, skipped: 1}

    assert {:error, :no_tests_run,
            %{
              phase: :baseline,
              excluded: 1,
              skipped: 1,
              include: [%{"kind" => "location", "file" => "test/a_test.exs", "line" => 8}],
              exclude: ["test", "database:off"]
            }} = Suite.require_tests(ran_none, filter, :baseline)
  end

  @tag spec: ["mutagen.coverage.r11", "mutagen.mutation_pipeline.r21"]
  test "an ExUnit raise becomes a sanitized run failure that names the phase" do
    assert {:error, :ex_unit_run_failed, %{message: message}} =
             Suite.run(RaisingExUnit, :coverage)

    assert message ==
             "ExUnit.run/0 raised during coverage: database password: [REDACTED] unavailable"
  end
end
