defmodule CalCom.MixProject do
  use Mix.Project

  @version "0.2.0"
  @source_url "https://github.com/hawkyre/cal_com"

  def project do
    [
      app: :cal_com,
      version: @version,
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: description(),
      package: package(),
      dialyzer: [plt_add_apps: [:mix, :dialyxir]]
    ]
  end

  # Test support compiles with lib so a synthetic schema is defined before
  # protocol consolidation; a schema defined inside a test file warns.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  # The package is a pure library: it builds requests and parses responses and
  # never opens a socket, so it starts no supervision tree of its own. It needs
  # :crypto for webhook HMACs and for the page digest a walk keeps.
  def application, do: [extra_applications: [:crypto]]

  # Runtime dependencies are constraint ranges on the majors this package is
  # generated and tested against, never exact pins, so a consumer on another
  # minor resolves without a conflict. Decimal arrives through Ecto and is not
  # constrained here: this package never names it.
  defp deps do
    [
      {:ecto, "~> 3.13"},
      {:typed_ecto_schema, "~> 0.4"},
      {:jason, "~> 1.2"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      # Dev only, for `scripts/certify.exs`: the package itself stays
      # transport-free, but certifying it against the live API needs a client.
      {:req, "~> 0.5", only: :dev, runtime: false}
    ]
  end

  defp description do
    "Typed Cal.com v2 API client: builds requests and parses responses, transport-free."
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      # `source/` ships with the package: the generated modules read their
      # contracts from it at compile time, and a consumer can regenerate them.
      files: ~w(lib priv source mix.exs .formatter.exs README.md CHANGELOG.md LICENSE)
    ]
  end
end
