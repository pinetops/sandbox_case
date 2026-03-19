defmodule SandboxCase.MixProject do
  use Mix.Project

  @source_url "https://github.com/pinetops/sandbox_case"
  @version "0.2.1"

  def project do
    [
      app: :sandbox_case,
      version: @version,
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      package: package(),
      description: "Batteries-included test isolation for Elixir and Phoenix.",
      deps: deps(),
      docs: docs()
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  def application do
    [extra_applications: []]
  end

  defp deps do
    [
      {:plug, "~> 1.14", optional: true},
      {:phoenix_live_view, "~> 1.0", optional: true},
      {:phoenix_ecto, "~> 4.0", optional: true},
      {:ex_doc, "~> 0.28", only: :dev, runtime: false},
      # Test deps — full Phoenix app for integration tests
      {:jason, "~> 1.0", only: :test},
      {:ecto_sql, "~> 3.12", only: :test},
      {:ecto_sqlite3, "~> 0.22", only: :test},
      {:bandit, "~> 1.0", only: :test},
      {:cachex, github: "pinetops/cachex", branch: "cachex-sandbox", only: :test},
      {:fun_with_flags, github: "pinetops/fun_with_flags", branch: "fwf-sandbox", only: :test, runtime: false},
      {:mimic, "~> 1.7", only: :test},
      {:mox, "~> 1.2", only: :test},
      {:lazy_html, ">= 0.1.0", only: :test}
    ]
  end

  defp package do
    [
      files: ["lib", "mix.exs", "README.md", "LICENSE.md"],
      maintainers: ["Tom Clarke"],
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url}
    ]
  end

  defp docs do
    [
      extras: ["README.md": [title: "Introduction"]],
      source_ref: "v#{@version}",
      source_url: @source_url,
      main: "readme"
    ]
  end
end
