defmodule PlugHTTPCache do
  @moduledoc """
  Plug that caches HTTP responses

  This plug library relies on the `http_cache` library. It supports all caching
  features of [RFC7234](https://datatracker.ietf.org/doc/html/rfc7234) and more
  (such as conditional requests and range requests).

  See `http_cache` documentation for more information.

  ## Configure

  In your plug pipeline, set the Plug for routes on which you want to enable caching:

  `router.ex`

        pipeline :cache do
          plug PlugHTTPCache, @caching_options
        end

        ...

        scope "/", PlugHTTPCacheDemoWeb do
          pipe_through :browser

          scope "/some_route" do
            pipe_through :cache

            ...
          end
        end

  You can also configure it for all requests by setting it in Phoenix's endpoint
  file:

  `endpoint.ex`

      defmodule MyApp.Endpoint do
        use Phoenix.Endpoint, otp_app: :plug_http_cache_demo

        % some other plugs

        plug Plug.RequestId
        plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]
        plug Plug.Parsers,
          parsers: [:urlencoded, :multipart, :json],
          pass: ["*/*"],
          json_decoder: Phoenix.json_library()
        plug Plug.Head
        plug Plug.Session, @session_options

        plug PlugHTTPCache, @caching_options

        plug PlugHTTPCacheDemoWeb.Router
      end

  Note that
  - chunked responses cannot be cached
  - some responses (called "cacheable by default") can be cached even when no
  `cache-control` header is set
  - Phoenix automatically sets the `"cache-control"` header to
  `"max-age=0, private, must-revalidate"`, so by default no response will ever
  be cached unless you override this header

  You can also configure `PlugHTTPCache.StaleIfError` to return expired cached responses.
  This is useful to continue returning something when the backend experiences failures
  (for example if the DB crashed and while it's rebooting).

  ## Application options

  - `max_workers`: the maximum of processes inserting responses in the store in parallel.
  Defaults to `16`. When a cacheable responses cannot be inserted because no worker
  is free, a [telemetry](#module-telemetry-events) event is emitted. This is a cheap
  mechanism to avoid overloading the system.

  ## Plug options

  Plug options are those documented by `t::http_cache.opts/0`.

  The only required option is `:store`.

  This plug sets the following default options:
  - `:type`: `:shared`,
  - `:auto_compress`: `true`,
  - `:auto_accept_encoding`: `true`

  ## Stores

  The store is responsible for storing the cached responses.
  [`http_cache_store_native`](https://github.com/tanguilp/http_cache_store_native)
  is a store that uses the native VM capabilities and is cluster aware.

  To use it along with this library, just add it to your mix.exs file:

  `mix.exs`

      {:plug_http_cache, "~> ..."},
      {:http_cache_store_native, "~> ..."},

  ## Security considerations

  Unlike many HTTP caches, `http_cache` allows caching:
  - responses to authorized request (with an `"authorization"` header)
  - responses with cookies

  In the first case, beware of authenticating before handling caching. In
  other words, **don't**:

      PlugHTTPCache, @caching options
      MyPlug.AuthorizeUser

  which would return a cached response to unauthorized users, but **do** instead:

      MyPlug.AuthorizeUser
      PlugHTTPCache, @caching options

  Beware of not setting caching headers on private responses containing cookies.

  ## Telemetry events

  The following events are emitted:
  - `[:plug_http_cache, :hit]` when a cached response is returned.
  - `[:plug_http_cache, :miss]` when no cached response was found
  - `[:plug_http_cache, :overloaded]` when there's no free worker to add the response

  Neither measurements nor metadata are added to these events.

  The `http_cache` and `http_cache_store_native` emit other more complete events about
  the caching subsytems, including some helping with detecting normalization issues.

  ## Normalization

  The underlying http caching library may store different responses for the same URL,
  following the directives of the `"vary"` header. For instance, if a response can
  be returned in English or in Russian, both versions can be cached as long as the
  `"vary"` header is correctly used.

  This can unfortunately result in an explosion of stored responses if the headers
  are not normalized. For instance, in this scenario where a site handles both these
  languages, a response will be stored for any of these requests that include an
  `"accept-language"` header:
  - fr-CH, fr;q=0.9, en;q=0.8, de;q=0.7, *;q=0.5
  - fr-CH, fr;q=0.9, en;q=0.8, de;q=0.7,*;q=0.5
  - en
  - ru
  - en, ru
  - en, ru, fr
  - en;q=1, ru
  - en;q=1, ru;q=0.9
  - en;q=1, ru;q=0.9
  - en;q=1, ru;q=0.8
  - en;q=1, ru;q=0.7
  - en;q=1, ru;q=0.6
  - en;q=1, ru;q=0.5

  and so on, so potentially hundreds of stored responses for only 2 available
  responses (English or Russian versions).

  In this case, you probably want to apply normalization before caching. This
  could be done by a plug set before the `PlugHTTPCache` plug.

  See [Best practices for using the Vary header](https://www.fastly.com/blog/best-practices-using-vary-header)
  for more guidance regarding this issue.

  """

  @behaviour Plug

  @default_caching_options [
      type: :shared,
      auto_compress: true,
      auto_accept_encoding: true
  ]

  @doc """
  Adds one or more alternate keys to the cached response

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

    Keyword.merge(@default_caching_options, opts)
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

  defp cache_response(%Plug.Conn{state: :set} = conn, opts) do
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

  defp cache_response(conn, _opts) do
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
      # a single reference to a binary versus possibly passing a IOlist to another
      # process, which would have to be copied
      :erlang.iolist_to_binary(conn.resp_body)
    }
  end

  defp req_body(%Plug.Conn{body_params: %Plug.Conn.Unfetched{}}), do: ""
  defp req_body(conn), do: :erlang.term_to_binary(conn.body_params)

  defp telemetry_log(event) do
    :telemetry.execute([:plug_http_cache, event], %{}, %{})
  end
end
