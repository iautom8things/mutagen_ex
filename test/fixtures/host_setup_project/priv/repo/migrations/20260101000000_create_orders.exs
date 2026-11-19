defmodule HostSetupFixture.Repo.Migrations.CreateOrders do
  use Ecto.Migration

  def change do
    create table(:orders) do
      add(:quantity, :integer, null: false)
    end
  end
end
