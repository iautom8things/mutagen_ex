false = Application.fetch_env!(:ex_unit, :autorun)

ExUnit.start(
  exclude: [:load, :pricing, database: :off],
  include: [:pricing],
  timeout: 5_000
)

Ecto.Adapters.SQL.Sandbox.mode(HostSetupFixture.Repo, :manual)
Mox.defmock(HostSetupFixture.PricingMock, for: HostSetupFixture.Pricing)
File.write!("runs.log", "helper\n", [:append])
