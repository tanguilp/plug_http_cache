defmodule PlugHTTPCache.MixProject do
  use Mix.Project

  def project do
    [
      app: :plug_http_cache,
      version: "0.1.0",
      elixir: "~> 1.10",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {PlugHTTPCache.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:dialyxir, "~> 1.0", only: [:dev], runtime: false},
      {:ex_doc, "~> 0.24", only: :dev, runtime: false},
      {:http_cache, path: "../http_cache", override: true},
      {:plug, "~> 1.0"},
      {:http_cache_store_native, path: "../http_cache_store_native", only: [:test]},
      {:telemetry, "~> 1.0"}
    ]
  end
end
