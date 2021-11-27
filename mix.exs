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
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:dialyxir, "~> 1.0", only: [:dev], runtime: false},
      {:http_cache, github: "tanguilp/http_cache"},
      {:plug, "~> 1.0"}
    ]
  end
end
