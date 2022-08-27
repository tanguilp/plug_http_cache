defmodule PlugHTTPCache do
  @moduledoc """
  A Plug that caches HTTP responses

  This plug library relies on the `http_cache` library. It supports all caching
  features of [RFC9111](https://datatracker.ietf.org/doc/html/rfc9111) and more
  (such as conditional requests and range requests).

  See [`http_cache`](https://hexdocs.pm/http_cache/) documentation for more information.

  ## Configuration

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

  Note that:
  - caching chunked responses is *not* supported
  - some responses (called "cacheable by default") can be cached even when no
  `cache-control` header is set. For instance, a 200 response to a get request is
  cached 2 minutes by default, unless `cache-control` headers prohibit it
  - Phoenix automatically sets the `"cache-control"` header to
  `"max-age=0, private, must-revalidate"`, so by default no response will ever
  be cached unless you override this header

  You can also configure `PlugHTTPCache.StaleIfError` to return expired cached responses.
  This is useful to continue returning something when the backend experiences failures
  (for example if the DB crashed and while it's rebooting).

  ## Plug options

  Plug options are those documented by `t::http_cache.opts/0`.

  The only required option is `:store`.

  This plug sets the following default options:
  - `:type`: `:shared`,
  - `:auto_compress`: `true`,
  - `:auto_accept_encoding`: `true`

  ## Stores

  A store is needed to store the cached responses. This library doesn't provide
  one by default.

  [`http_cache_store_native`](https://github.com/tanguilp/http_cache_store_native)
  is such a store and uses the native VM capabilities and is cluster aware.

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

      PlugHTTPCache, @caching_options
      MyPlug.AuthorizeUser

  which would return a cached response to unauthorized users, but **do** instead:

      MyPlug.AuthorizeUser
      PlugHTTPCache, @caching_options

  Beware of not setting caching headers on private responses containing cookies.

  ## Useful libraries

  - [`PlugCacheControl`](https://github.com/krasenyp/plug_cache_control) can be used
  to set cache-control headers in your Plug pipelines, or manually in your controllers
  - [`PlugHTTPValidator`](https://github.com/tanguilp/plug_http_validator) *should* be used
  to set HTTP validators as soon as cacheable content is returned. See project
  documentation to figure out why

  ## Telemetry events

  The following events are emitted:
  - `[:plug_http_cache, :hit]` when a cached response is returned.
  - `[:plug_http_cache, :miss]` when no cached response was found
  - `[:plug_http_cache, :stale_if_error]` when a response was returned because an error
  occurred downstream (see `PlugHTTPCache.StaleIfError`)

  Neither measurements nor metadata are added to these events.

  The `http_cache` and `http_cache_store_native` emit other events about
  the caching subsystems, including some helping with detecting normalization issues.

  ## Normalization

  The underlying http caching library may store different responses for the same URL,
  following the directives of the `"vary"` header. For instance, if a response can
  be returned in English or in French, both versions can be cached as long as the
  `"vary"` header is correctly used.

  This can unfortunately result in an explosion of stored responses if the headers
  are not normalized. For instance, in this scenario where a site handles both these
  languages, a response will be stored for any of these requests that include an
  `"accept-language"` header:
  - fr-CH, fr;q=0.9, en;q=0.8, de;q=0.7, *;q=0.5
  - fr-CH, fr;q=0.9, en;q=0.8, de;q=0.7,*;q=0.5
  - en
  - de
  - en, de
  - en, de, fr
  - en;q=1, de
  - en;q=1, de;q=0.9
  - en;q=1, de;q=0.8
  - en;q=1, de;q=0.7
  - en;q=1, de;q=0.6
  - en;q=1, de;q=0.5

  and so on, so potentially hundreds of stored responses for only 2 available
  responses (English and French versions).

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
  @spec set_alternate_keys(
          Plug.Conn.t(),
          :http_cache.alternate_key() | [:http_cache.alternate_key()]
        ) :: Plug.Conn.t()
  def set_alternate_keys(conn, []) do
    conn
  end

  def set_alternate_keys(
        %Plug.Conn{private: %{plug_http_cache_alt_keys: existing_alt_keys}} = conn,
        alt_keys
      )
      when is_list(existing_alt_keys) and is_list(alt_keys) do
    put_in(conn.private[:plug_http_cache_alt_keys], existing_alt_keys ++ alt_keys)
  end

  def set_alternate_keys(conn, alt_keys) when is_list(alt_keys) do
    put_in(conn.private[:plug_http_cache_alt_keys], [])
    |> set_alternate_keys(alt_keys)
  end

  def set_alternate_keys(conn, alt_keys) do
    set_alternate_keys(conn, [alt_keys])
  end

  @impl true
  def init(opts) do
    unless opts[:store], do: raise("missing `:store` option for `:http_cache`")

    Keyword.merge(@default_caching_options, opts)
  end

  @impl true
  def call(conn, opts) do
    case :http_cache.get(request(conn), opts) do
      {:fresh, {resp_ref, response}} ->
        telemetry_log(:hit)
        send_response(conn, resp_ref, response, opts)

      {:stale, {resp_ref, response}} ->
        telemetry_log(:hit)

        if opts[:allow_stale_if_error], do: telemetry_log(:stale_if_error)

        send_response(conn, resp_ref, response, opts)

      _ ->
        telemetry_log(:miss)
        install_callback(conn, opts)
    end
  end

  defp send_response(conn, resp_ref, response, opts) do
    :http_cache.notify_response_used(resp_ref, opts)

    send_response(conn, response)
  end

  defp send_response(conn, {status, resp_headers, {:sendfile, offset, length, path}}) do
    %Plug.Conn{conn | resp_headers: resp_headers}
    |> Plug.Conn.send_file(status, path, offset, length)
    |> Plug.Conn.halt()
  end

  defp send_response(conn, {status, resp_headers, iodata_body}) do
    %Plug.Conn{conn | resp_headers: resp_headers}
    |> Plug.Conn.send_resp(status, iodata_body)
    |> Plug.Conn.halt()
  end

  defp install_callback(conn, opts) do
    Plug.Conn.register_before_send(conn, &cache_response(&1, opts))
  end

  defp cache_response(%Plug.Conn{state: :set} = conn, opts) do
    alt_keys = alt_keys(conn)
    http_cache_opts = [{:alternate_keys, alt_keys} | opts]

    case :http_cache.cache(request(conn), response(conn), http_cache_opts) do
      {:ok, _} ->
        # We can't use the response returned by :http_cache because Plug disallow changing
        # a response that is already :set
        conn

      :not_cacheable ->
        conn
    end
  end

  defp cache_response(conn, _opts) do
    conn
  end

  defp alt_keys(%Plug.Conn{private: %{plug_http_cache_alt_keys: alt_keys}}),
    do: Enum.dedup(alt_keys)

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
