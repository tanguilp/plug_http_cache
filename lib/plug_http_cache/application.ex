defmodule PlugHTTPCache.Application do
  @moduledoc false

  use Application

  @max_workers Application.compile_env(:plug_http_cache, :max_workers, 16)

  @impl true
  def start(_type, _args) do
    children = [
      {Task.Supervisor, name: PlugHTTPCache.WorkerSupervisor, max_children: @max_workers}
    ]

    opts = [strategy: :one_for_one, name: PlugHTTPCache.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
