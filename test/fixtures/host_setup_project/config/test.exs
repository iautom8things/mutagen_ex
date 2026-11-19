import Config

host = System.get_env("HOST_SETUP_DB_HOST", "/tmp")
address = if String.starts_with?(host, "/"), do: [socket_dir: host], else: [hostname: host]

config :host_setup_fixture,
  ecto_repos: [HostSetupFixture.Repo],
  pricing: HostSetupFixture.PricingMock

config :host_setup_fixture,
       HostSetupFixture.Repo,
       [
         username: System.get_env("HOST_SETUP_DB_USER", System.get_env("USER", "postgres")),
         password: System.get_env("HOST_SETUP_DB_PASSWORD", ""),
         port: String.to_integer(System.get_env("HOST_SETUP_DB_PORT", "5432")),
         database:
           System.get_env("HOST_SETUP_DB_NAME", "mutagen_host_setup") <>
             to_string(System.get_env("MIX_TEST_PARTITION")),
         pool: Ecto.Adapters.SQL.Sandbox,
         pool_size: 2
       ] ++ address

config :logger, :default_handler, config: [type: :standard_error]
