defmodule Stressgrid.Coordinator.MixProject do
  use Mix.Project

  def project do
    [
      app: :coordinator,
      version: "0.1.0",
      elixir: "~> 1.7",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Stressgrid.Coordinator.Application, []}
    ]
  end

  defp deps do
    [
      {:cowboy, "~> 2.6"},
      {:jason, "~> 1.1"},
      {:hdr_histogram, "~> 0.3.2"},
      {:ex_aws_cloudwatch, "~> 2.0"},
      {:httpoison, "~> 1.6"}
    ]
  end
end
