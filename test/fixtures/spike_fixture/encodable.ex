defprotocol SpikeFixture.Encodable do
  @moduledoc """
  Tiny protocol used to exercise the `defimpl` path through bytecode
  restore in the C1 spike.
  """

  @spec encode(t) :: String.t()
  def encode(value)
end

defmodule SpikeFixture.EncodableImpl do
  @moduledoc """
  Struct + protocol implementation. C1's restore must round-trip both
  the struct's `defstruct` and the `defimpl` bytecode that follows.
  """

  defstruct [:name]
end

defimpl SpikeFixture.Encodable, for: SpikeFixture.EncodableImpl do
  def encode(%SpikeFixture.EncodableImpl{name: name}) do
    "name=" <> to_string(name)
  end
end
