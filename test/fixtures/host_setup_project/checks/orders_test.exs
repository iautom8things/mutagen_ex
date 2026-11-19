defmodule HostSetupFixture.OrdersTest do
  use HostSetupFixture.DataCase, async: true

  import Mox

  alias HostSetupFixture.{Order, Orders, PricingMock, Repo}

  setup_all do
    assert_raise DBConnection.OwnershipError, fn -> Repo.query!("SELECT 1") end
    :ok
  end

  setup :verify_on_exit!

  @tag :pricing
  test "prices an order above the surcharge threshold" do
    assert ExUnit.configuration()[:timeout] == 5_000
    assert Repo.aggregate(Order, :count) == 0

    assert Repo.config()[:database] ==
             System.fetch_env!("HOST_SETUP_DB_NAME") <>
               to_string(System.get_env("MIX_TEST_PARTITION"))

    expect(PricingMock, :rate, fn -> 4 end)
    order = Repo.insert!(%Order{quantity: 3})
    actual = Orders.price(order.id)
    File.write!("runs.log", "order\n", [:append])
    assert actual == 14
  end

  @tag :load
  test "would fail if the helper's exclusion were ignored" do
    File.write!("runs.log", "load\n", [:append])
    flunk("load test ran")
  end

  @tag database: :off
  test "would fail if the helper's keyword exclusion were ignored" do
    flunk("database-off test ran")
  end
end
