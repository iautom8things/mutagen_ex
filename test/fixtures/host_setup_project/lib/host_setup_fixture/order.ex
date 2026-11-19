defmodule HostSetupFixture.Order do
  use Ecto.Schema

  schema "orders" do
    field(:quantity, :integer)
  end
end
