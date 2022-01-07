defmodule PlugHTTPCache.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @max_workers Application.compile_env(:plug_http_cache, :max_workers, 50)

  @impl true
  def start(_type, _args) do
    children = [
      {Task.Supervisor, name: PlugHTTPCache.WorkerSupervisor, max_children: @max_workers}
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: PlugHTTPCache.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
