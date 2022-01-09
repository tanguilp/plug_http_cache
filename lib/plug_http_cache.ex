defmodule PlugHTTPCache do
  @moduledoc """
  Documentation for PlugHttpCache.
  """

  @behaviour Plug

  @doc """
  Adds one or more alternate keys to the request

  Request with alternate keys can be later be invalidated with the
  `:http_cache.invalidate_by_alternate_key/2` function.
  """
  @spec set_alternate_keys(Plug.Conn.t(), :http_cache.alternate_key() | [:http_cache.alternate_key()]) :: Plug.Conn.t()
  def set_alternate_keys(conn, []) do
    conn
  end

  def set_alternate_keys(
    %Plug.Conn{private: %{plug_http_cache_alt_keys: existing_alt_keys}} = conn,
    alt_keys
  ) when is_list(alt_keys) do
    put_in(conn.private[:plug_http_cache_alt_keys], existing_alt_keys ++ alt_keys)
  end

  def set_alternate_keys(conn, alt_keys) do
    put_in(conn.private[:plug_http_cache_alt_keys], [])
    |> set_alternate_keys(alt_keys)
  end

  @impl true
  def init(opts) do
    unless opts[:store], do: raise "missing `:store` option for `:http_cache`"
    unless opts[:type], do: raise "missing `:type` option for `:http_cache`"

    opts
  end

  @impl true
  def call(conn, opts) do
    case :http_cache.get(request(conn), opts) do
      {:ok, {resp_ref, response}} ->
        telemetry_log(:hit)
        send_cached(conn, resp_ref, response, opts)

      {:stale, {resp_ref, response}} ->
        telemetry_log(:hit)
        send_cached(conn, resp_ref, response, opts)

      _ ->
        telemetry_log(:miss)
        install_callback(conn, opts)
    end
  end

  defp send_cached(conn, resp_ref, {_status, resp_headers, _body} = response, opts) do
    :http_cache.notify_use(resp_ref, opts)

    %Plug.Conn{conn | resp_headers: resp_headers}
    |> do_send_cached(response)
    |> Plug.Conn.halt()
  end

  defp do_send_cached(conn, {status, _resp_headers, {:sendfile, offset, length, path}}) do
    Plug.Conn.send_file(conn, status, path, offset, length)
  end

  defp do_send_cached(conn, {status, _resp_headers, iodata_body}) do
    Plug.Conn.send_resp(conn, status, iodata_body)
  end

  defp install_callback(conn, opts) do
    Plug.Conn.register_before_send(conn, &cache_response(&1, opts))
  end

  @doc false
  def cache_response(%Plug.Conn{state: :set} = conn, opts) do
    alt_keys = alt_keys(conn)
    http_cache_opts = [{:alternate_keys, alt_keys} | opts]

    Task.Supervisor.start_child(
      PlugHTTPCache.WorkerSupervisor,
      :http_cache,
      :cache,
      [request(conn), response(conn), http_cache_opts],
      shutdown: :brutal_kill
    )
    |> case do
      {:error, :max_children} ->
        telemetry_log(:overloaded)

      _ ->
        :ok
    end

    conn
  end

  def cache_response(conn, _opts) do
    conn
  end

  defp alt_keys(%Plug.Conn{private: %{plug_http_cache_alt_keys: alt_keys}}), do: Enum.dedup(alt_keys)
  defp alt_keys(_), do: []

  defp request(conn) do
    {
      conn.method,
      Plug.Conn.request_url(conn),
      conn.req_headers,
      req_body(conn)
    }
  end

  defp response(conn) do
    {
      conn.status,
      conn.resp_headers,
      # We convert to binary before sending to another process to benefit from passing
      # a single reference to a binary versus possibly passing a IOlist to another process,
      # which would have to be copied
      :erlang.iolist_to_binary(conn.resp_body)
    }
  end

  defp req_body(%Plug.Conn{body_params: %Plug.Conn.Unfetched{}}), do: ""
  defp req_body(conn), do: :erlang.term_to_binary(conn.body_params)

  defp telemetry_log(event) do
    :telemetry.execute([:plug_http_cache, event], %{}, %{})
  end
end
