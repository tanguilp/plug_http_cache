defmodule PlugHTTPCache.MixProject do
  use Mix.Project

  def project do
    [
      app: :plug_http_cache,
      description: "A Plug that caches HTTP responses",
      version: "0.4.1",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      docs: [
        main: "readme",
        extras: ["README.md", "CHANGELOG.md"]
      ],
      package: package(),
      dialyzer: [plt_add_apps: [:http_cache]],
      source_url: "https://github.com/tanguilp/plug_http_cache"
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
      {:ex_doc, "~> 0.24", only: :dev, runtime: false},
      {:http_cache, "~> 0.4.0", optional: true},
      {:http_cache_store_memory, "~> 0.3.0", only: :test},
      {:phoenix, "~> 1.0", only: :test},
      {:plug, "~> 1.0"},
      {:plug_loopback, "~> 0.1.0"},
      {:telemetry, "~> 1.0"}
    ]
  end

  def package() do
    [
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => "https://github.com/tanguilp/plug_http_cache"}
    ]
  end
end
