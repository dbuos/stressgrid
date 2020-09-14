defmodule Stressgrid.Generator.Mixfile do
  use Mix.Project

  def project do
    [
      app: :generator,
      version: "0.1.0",
      elixir: "~> 1.9",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Stressgrid.Generator.Application, []}
    ]
  end

  defp deps do
    [
      {:gun, "~> 1.3.0"},
      {:hdr_histogram,
       git: "https://github.com/HdrHistogram/hdr_histogram_erl.git",
       tag: "075798518aabd73a0037007989cde8bd6923b4d9"},
      {:jason, "~> 1.1"},
      {:bertex, "~> 1.3"},
      {:dialyxir, "~> 1.0.0-rc.7", runtime: false}
    ]
  end
end
