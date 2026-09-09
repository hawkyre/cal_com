defmodule CalCom.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/hawkyre/cal_com"

  def project do
    [
      app: :cal_com,
      version: @version,
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: description(),
      package: package(),
      dialyzer: [plt_add_apps: [:mix, :dialyxir]]
    ]
  end

  # The package is a pure library: it builds requests and parses responses and
  # never opens a socket, so it starts no supervision tree of its own.
  def application, do: [extra_applications: []]

  # Runtime dependencies are constraint ranges on the majors this package is
  # generated and tested against, never exact pins, so a consumer on another
  # minor resolves without a conflict.
  defp deps do
    [
      {:ecto, "~> 3.13"},
      {:typed_ecto_schema, "~> 0.4"},
      {:jason, "~> 1.2"},
      {:decimal, "~> 2.0"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp description do
    "Typed Cal.com v2 API client: builds requests and parses responses, transport-free."
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url}
    ]
  end
end
