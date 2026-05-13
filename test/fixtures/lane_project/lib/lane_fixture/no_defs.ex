defmodule LaneFixture.NoDefs do
  @moduledoc """
  Module with no public functions, no struct, no `use`.

  Exercises the `:no_mutation_candidates` warning path
  (`mutagen.mutation_enumeration.r5`): a scope that walks this module
  must emit a warning naming the module and produce zero mutation sites.

  The only content is this module-doc string and a couple of inert
  module attributes, which do not match any mutator's `match?/1`.
  """

  @some_constant :stable
  @another_constant "no-mutations-here"

  def constants, do: {@some_constant, @another_constant}
end
