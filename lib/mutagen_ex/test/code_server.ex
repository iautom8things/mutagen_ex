defmodule MutagenEx.Test.CodeServer do
  @moduledoc """
  Production implementation of `MutagenEx.Test.CodeServerFacade` — a
  thin pass-through to the `:code` module.

  Tests swap a different module via the `:code_server` config key
  (the same way the runner selects the `:compiler` seam).
  """

  @behaviour MutagenEx.Test.CodeServerFacade

  @impl MutagenEx.Test.CodeServerFacade
  def get_object_code(module), do: :code.get_object_code(module)

  @impl MutagenEx.Test.CodeServerFacade
  def load_binary(module, filename, binary), do: :code.load_binary(module, filename, binary)
end
