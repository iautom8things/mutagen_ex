ExUnit.start(exclude: [:load])
Ecto.Adapters.SQL.Sandbox.mode(HostSetupFixture.Repo, :manual)
Mox.defmock(HostSetupFixture.PricingMock, for: HostSetupFixture.Pricing)
File.write!("runs.log", "helper\n", [:append])
