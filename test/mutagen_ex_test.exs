defmodule MutagenExTest do
  use ExUnit.Case
  doctest MutagenEx

  test "greets the world" do
    assert MutagenEx.hello() == :world
  end
end
