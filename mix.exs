defmodule PhoenixTestOnly.MixProject do
  use Mix.Project

  @source_url "https://github.com/pinetops/phoenix_test_only"
  @version "0.2.0"

  def project do
    [
      app: :phoenix_test_only,
      version: @version,
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      package: package(),
      description: "Compile-time conditional plug/on_mount for test-only modules.",
      deps: deps(),
      docs: docs()
    ]
  end

  def application do
    [extra_applications: []]
  end

  defp deps do
    [
      {:ex_doc, "~> 0.28", only: :dev, runtime: false}
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
