defmodule LaneFixture.EctoUserSchema do
  @moduledoc """
  Hand-rolled DSL macro module — C1 fixture analogue for the lane project.

  Mirrors what `use Ecto.Schema` does at a smaller scale: register a
  persisted attribute and inject a callback that exposes the registered
  value. This module is a sibling to `LaneFixture.EctoUser` (NOT a
  nested module) so the production scope resolver's `Module.concat`
  pattern resolves cleanly without the nested-defmodule surface bug.
  """

  defmacro __using__(_opts) do
    quote do
      @before_compile LaneFixture.EctoUserSchema
      Module.register_attribute(__MODULE__, :lane_schema_kind, persist: true)
      @lane_schema_kind :registered

      import LaneFixture.EctoUserSchema, only: [field: 2]
    end
  end

  defmacro field(name, type) do
    quote do
      @lane_schema_kind :registered
      def unquote(name)(), do: unquote(type)
    end
  end

  defmacro __before_compile__(_env) do
    quote do
      def __schema_kind__, do: :registered
    end
  end
end

defmodule LaneFixture.EctoUser do
  @moduledoc """
  C1 fixture analogue: a module that uses a hand-rolled DSL macro.

  Mirrors `use Ecto.Schema` at small scale via `LaneFixture.EctoUserSchema`.
  The end-to-end test asserts that after a full mutation pass against
  this module, both the macro-injected callbacks AND the module's
  bytecode MD5 survive every restore cycle — Spike I invariants
  re-run.
  """

  use LaneFixture.EctoUserSchema

  field(:name, :string)
  field(:age, :integer)

  @doc """
  A plain arithmetic helper outside the macro DSL gives the mutator
  catalog a site to chew on while the macro-injected callbacks must
  survive every restore.
  """
  def birthday(age) when is_integer(age), do: age + 1
end
