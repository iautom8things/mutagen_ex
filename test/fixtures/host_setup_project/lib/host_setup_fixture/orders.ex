defmodule HostSetupFixture.Orders do
  require Logger

  alias HostSetupFixture.Order
  alias HostSetupFixture.Repo

  def price(id) do
    Logger.warning("pricing an order from the host fixture")
    order = Repo.get!(Order, id)
    pricing = Application.fetch_env!(:host_setup_fixture, :pricing)
    total = order.quantity * pricing.rate()

    if total >= 10 do
      total + 2
    else
      total
    end
  end
end
