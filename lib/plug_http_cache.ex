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

  Plug options are those documented by
  [`:http_cache.opts/0`](https://hexdocs.pm/http_cache/http_cache.html#t:opts/0).

  The only required option is `:store`.

  This plug sets the following default options:
  - `:type`: `:shared`,
  - `:auto_compress`: `true`,
  - `:auto_accept_encoding`: `true`
  - `:stale_while_revalidate_supported`: `true`

  ## Stores

  Responses have to be stored in a separate store backend (this library does not come with one), such
  as:
  - [`http_cache_store_memory`](https://github.com/tanguilp/http_cache_store_memory): responses are
  stored in memory (ETS)
  - [`http_cache_store_disk`](https://github.com/tanguilp/http_cache_store_disk): responses are
  stored on disk. An application using the `sendfile` system call (such as
  [`plug_http_cache`](https://github.com/tanguilp/plug_http_cache)) may benefit from the kernel's
  memory caching automatically

  Both are cluster-aware.

  To use it along with this library, just add it to your mix.exs file:

  `mix.exs`

  ```elixir
  {:plug_http_cache, "~> ..."},
  {:http_cache_store_memory, "~> ..."},
  ```

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

  `conn` is added to the events' metadata.

  The `http_cache`, `http_cache_store_memory` and `http_cache_store_disk` emit other events about
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

  @default_caching_options %{
    type: :shared,
    auto_compress: true,
    auto_accept_encoding: true,
    stale_while_revalidate_supported: true
  }

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
    Map.merge(@default_caching_options, opts)
  end

  @impl true
  def call(conn, opts) do
    http_cache_request = request(conn)

    case :http_cache.get(http_cache_request, opts) do
      {:fresh, {resp_ref, response}} ->
        telemetry_log(:hit, conn)
        notify_and_send_response(conn, resp_ref, response, opts)

      {:stale, {resp_ref, response}} ->
        if revalidate_stale_response?(response, opts),
          do: revalidate_stale_response(conn, response)

        telemetry_log(:hit, conn)
        notify_and_send_response(conn, resp_ref, response, opts)

      _ ->
        telemetry_log(:miss, conn)
        conn = install_callback(conn, opts)

        :http_cache.notify_downloading(http_cache_request, self(), opts)

        conn
    end
  end

  @doc false
  def notify_and_send_response(conn, resp_ref, response, opts) do
    :http_cache.notify_response_used(resp_ref, opts)

    send_response(conn, response, opts)
  end

  @doc false
  def send_response(conn, {status, resp_headers, {:sendfile, offset, length, path}}, opts) do
    %Plug.Conn{conn | resp_headers: resp_headers}
    |> Plug.Conn.send_file(status, path, offset, length)
    |> Plug.Conn.halt()
  rescue
    e ->
      case e do
        %File.Error{reason: :enoent} ->
          telemetry_log(:miss, conn)
          install_callback(conn, opts)

        _ ->
          reraise e, __STACKTRACE__
      end
  end

  def send_response(conn, {status, resp_headers, iodata_body}, _opts) do
    %Plug.Conn{conn | resp_headers: resp_headers}
    |> Plug.Conn.send_resp(status, iodata_body)
    |> Plug.Conn.halt()
  end

  defp install_callback(conn, opts) do
    Plug.Conn.register_before_send(conn, &cache_response(&1, opts))
  end

  defp cache_response(%Plug.Conn{state: :set} = conn, opts) do
    alt_keys = alt_keys(conn)
    http_cache_opts = Map.put(opts, :alternate_keys, alt_keys)

    # The response is already sent and we cannot modify it with the result of :http_cache.cache/3,
    # hence we don't use the result of this function
    :http_cache.cache(request(conn), response(conn), http_cache_opts)

    conn
  end

  defp cache_response(conn, _opts) do
    conn
  end

  defp alt_keys(%Plug.Conn{private: %{plug_http_cache_alt_keys: alt_keys}}),
    do: Enum.dedup(alt_keys)

  defp alt_keys(_), do: []

  defp revalidate_stale_response(conn, cached_response) do
    {_, cached_headers, _} = cached_response

    Task.start(fn ->
      conn
      |> PlugLoopback.replay()
      |> Plug.Conn.update_req_header("cache-control", "max-stale=0", &(&1 <> ", max-stale=0"))
      |> add_validator(cached_headers, "last-modified", "if-modified-since")
      |> add_validator(cached_headers, "etag", "if-none-match")
      |> PlugLoopback.run()
    end)
  end

  defp add_validator(conn, cached_headers, validator, condition_header) do
    cached_headers
    |> Enum.find(fn {header_name, _} -> String.downcase(header_name) == validator end)
    |> case do
      {_, header_value} ->
        Plug.Conn.put_req_header(conn, condition_header, header_value)

      nil ->
        conn
    end
  end

  @doc false
  def request(conn) do
    {
      conn.method,
      request_url(conn),
      conn.req_headers,
      req_body(conn)
    }
  end

  defp request_url(conn) do
    IO.iodata_to_binary([
      to_string(conn.scheme),
      "://",
      conn.host,
      request_url_port(conn.scheme, conn.port),
      conn.request_path,
      request_url_qs(conn.query_string)
    ])
  end

  defp request_url_port(:http, 80), do: ""
  defp request_url_port(:https, 443), do: ""
  defp request_url_port(_, port), do: [?:, Integer.to_string(port)]

  # Conn's QS is by default not rfc3986 encoded…
  defp request_url_qs(""), do: ""

  defp request_url_qs(qs),
    do: [??, qs |> :uri_string.dissect_query() |> :uri_string.compose_query()]

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

  defp revalidate_stale_response?(response, opts) do
    {_status, headers, _body} = response

    # In theory we could erroneously revalidate a response with an expired timeout in
    # `stale-while-revalidate` if the `max-stale` is used as well and as a greater duration.
    # In practice this is deemed good enough™ for now

    opts[:stale_while_revalidate_supported] == true and
      Enum.any?(headers, fn {name, value} ->
        String.downcase(name) == "cache-control" and
          String.contains?(value, "stale-while-revalidate=")
      end)
  end

  defp req_body(%Plug.Conn{body_params: %Plug.Conn.Unfetched{}}), do: ""
  defp req_body(%Plug.Conn{body_params: %{} = map}) when map_size(map) == 0, do: ""
  defp req_body(conn), do: :erlang.term_to_binary(conn.body_params)

  @doc false
  def telemetry_log(event, conn) do
    :telemetry.execute([:plug_http_cache, event], %{}, %{conn: conn})
  end
end
