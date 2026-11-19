defmodule HostSetupFixture.MixProject do
  use Mix.Project

  def project do
    [
      app: :host_setup_fixture,
      version: "0.0.0",
      elixir: "~> 1.19",
      elixirc_paths: elixirc_paths(Mix.env()),
      test_paths: ["checks"],
      deps: deps()
    ]
  end

  def application do
    [mod: {HostSetupFixture.Application, []}]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:ecto_sql, "~> 3.13"},
      {:postgrex, "~> 0.22.0"},
      {:mox, "~> 1.2", only: :test}
    ] ++ mutagen_dep(System.get_env("HOST_SETUP_MUTAGEN_PATH"))
  end

  defp mutagen_dep(nil), do: []
  defp mutagen_dep(path), do: [{:mutagen_ex, path: path}]
end
