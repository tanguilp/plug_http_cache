defmodule PlugHTTPCache.StaleIfError do
  @moduledoc """
  Return stale entries when backend fails

  This module can help returning stale responses when the backend is temporarily
  unusable (for instance when restarting the DB) or when some unexpected errors occur.
  One of this known errors by Elixir developers is the

      ** (DBConnection.ConnectionError) connection not available and request was dropped from queue after 2655ms. This means requests are coming in and your connection pool cannot serve them fast enough. You can address this by:

          1. By tracking down slow queries and making sure they are running fast enough
          2. Increasing the pool_size (albeit it increases resource consumption)
          3. Allow requests to wait longer by increasing :queue_target and :queue_interval

      See DBConnection.start_link/2 for more information

  ecto errors which occur when it is under intense stress.

  Whenever a fresh response is found, it is returned by the `PlugHTTPCache` plug. Stale
  responses, however, aren't. Stale responses are those whose expiration has been reached
  but are still keep in the cache until the grace period is expired.

  By default, the `http_cache` library caches cacheable responses 2 minutes, and keep
  them 2 more minutes (which is called the *grace period*). By setting this module in your
  plug pipeline, a stale response can be returned whenever an exception is raised by the
  backend by adding this at the beginning of the router:

      use PlugHTTPCache.StaleIfError, ... % same options as when using `PlugHTTPCache`

  When using it jointly with `Plug.ErrorHandler`, you should add it before:

      use PlugHTTPCache.StaleIfError, ... % same options as when using `PlugHTTPCache`
      use Plug.ErrorHandler

  so that it is called before `Plug.ErrorHandler`'s generic error handling. In this case,
  if a stale response if found, it is returned. Otherwise, the error handler of
  `Plug.ErrorHandler` is called.

  Staled responses are returned only when the `"stale-if-error"` cache control directive
  is used, either in the request or in the response.

  As very few clients use it, you probably want to use it server side by setting
  this directive before returning the response in your controllers:

      conn
      |> put_resp_header("cache-control", "stale-if-error=600")
      ...

  One can also not "cache" response, but still keep staled versions to keep some pages
  showing even in case of serious trouble on the backend:

      conn
      |> put_resp_header("cache-control", "max-age=0, stale-if-error=600")
      ...

  Such a response will not be reused except by this module, in case of error.

  Note that as with the `Plug.ErrorHandler` module, error is reraised in any case.
  """

  defmacro __using__(opts) do
    opts = PlugHTTPCache.init(opts)

    quote bind_quoted: [opts: opts] do
      @before_compile PlugHTTPCache.StaleIfError

      @__stale_if_error_opts__ opts
    end
  end

  @doc false
  defmacro __before_compile__(_env) do
    quote location: :keep do
      defoverridable call: 2

      def call(conn, opts) do
        try do
          super(conn, opts)
        rescue
          e in Plug.Conn.WrapperError ->
            %{conn: conn, kind: kind, stack: stack} = e
            PlugHTTPCache.StaleIfError.__handle_error__(
              conn,
              kind,
              e,
              stack,
              @__stale_if_error_opts__
            )
        catch
          kind, reason ->
            PlugHTTPCache.StaleIfError.__handle_error__(
              conn,
              kind,
              reason,
              __STACKTRACE__,
              @__stale_if_error_opts__
            )
        end
      end
    end
  end

  @already_sent {:plug_conn, :sent}

  @doc false
  def __handle_error__(conn, kind, reason, stack, opts) do
    receive do
      @already_sent ->
        send(self(), @already_sent)

        conn
    after
      0 ->
        opts = Keyword.put(opts, :allow_stale_if_error, true)

        PlugHTTPCache.call(conn, opts)
    end

    :erlang.raise(kind, reason, stack)
  end
end
