false = Application.fetch_env!(:ex_unit, :autorun)

ExUnit.start(
  exclude: [:load, :pricing, database: :off],
  include: [:pricing],
  timeout: 5_000
)

Ecto.Adapters.SQL.Sandbox.mode(HostSetupFixture.Repo, :manual)
Mox.defmock(HostSetupFixture.PricingMock, for: HostSetupFixture.Pricing)
File.write!("runs.log", "helper\n", [:append])

opts =
  Keyword.take(
    HostSetupFixture.Repo.config(),
    ~w(hostname port username password database socket_dir)a
  )

{:ok, cleanup_conn} = Postgrex.start_link(opts)
Postgrex.query!(cleanup_conn, "CREATE SCHEMA mutagen_source_cleanup", [])

ExUnit.after_suite(fn _stats ->
  Postgrex.query!(cleanup_conn, "DROP SCHEMA mutagen_source_cleanup", [])
  GenServer.stop(cleanup_conn)
  File.write!("runs.log", "cleanup\n", [:append])
end)
