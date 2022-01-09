defmodule PlugHTTPCache.StaleIfErrorTest do
  use ExUnit.Case, async: true
  use Plug.Test

  @http_cache_opts type: :shared, store: :http_cache_store_native

  defmodule Router do
    use Plug.Router
    use PlugHTTPCache.StaleIfError, type: :shared, store: :http_cache_store_native
    use Plug.ErrorHandler

    plug :match
    plug :dispatch

    get "/boom" do
      raise "oops"
    end
  end

  test "stale response is returned when header is set in response" do
    conn = conn(:get, "/boom")

    request = {"GET", Plug.Conn.request_url(conn), [], ""}
    response = {200, [{"cache-control", "stale-if-error=30, max-age=0"}], "Some response"}
    :http_cache.cache(request, response, @http_cache_opts)

    assert_raise Plug.Conn.WrapperError, "** (RuntimeError) oops", fn ->
      Router.call(conn, [])
    end
    assert_received {:plug_conn, :sent}
    assert {200, _headers, "Some response"} = sent_resp(conn)
  end

  test "stale response is returned when header is set in request" do
    conn =
      conn(:get, "/boom")
      |> put_req_header("cache-control", "stale-if-error=30")

    request = {"GET", Plug.Conn.request_url(conn), conn.req_headers, ""}
    response = {200, [{"cache-control", "max-age=0"}], "Some response"}
    :http_cache.cache(request, response, @http_cache_opts)

    assert_raise Plug.Conn.WrapperError, "** (RuntimeError) oops", fn ->
      Router.call(conn, [])
    end
    assert_received {:plug_conn, :sent}
    assert {200, _headers, "Some response"} = sent_resp(conn)
  end

  test "stale response is not returned when header is missing" do
    conn = conn(:get, "/boom")

    request = {"GET", Plug.Conn.request_url(conn), [], ""}
    response = {200, [{"cache-control", "max-age=0"}], "Some response"}
    :http_cache.cache(request, response, @http_cache_opts)

    assert_raise Plug.Conn.WrapperError, "** (RuntimeError) oops", fn ->
      Router.call(conn, [])
    end

    refute match?({200, _headers, _body}, sent_resp(conn))
  end
end
