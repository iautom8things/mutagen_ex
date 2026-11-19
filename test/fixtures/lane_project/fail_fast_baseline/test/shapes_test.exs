defmodule FailFastBaseline.SetupAllTest do
  use ExUnit.Case, async: true

  setup_all context do
    if context.module == __MODULE__, do: raise("setup_all boom")
    :ok
  end

  test "a", do: :ok
  test "b", do: :ok
end

defmodule FailFastBaseline.TeardownTest do
  use ExUnit.Case

  setup_all do
    on_exit(fn -> raise "teardown boom" end)
  end

  test "c", do: :ok
end

defmodule FailFastBaseline.PlainTest do
  use ExUnit.Case, async: true

  test "d fails", do: flunk("d")
  test "e passes", do: :ok
end
