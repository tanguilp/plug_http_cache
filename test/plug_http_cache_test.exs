defmodule PlugHttpCacheTest do
  use ExUnit.Case
  use Plug.Test

  @hit_telemetry_event [:plug_http_cache, :hit]
  @miss_telemetry_event [:plug_http_cache, :miss]

  defmodule Router do
    use Plug.Router

    plug PlugHTTPCache, store: :http_cache_store_process
    plug :match
    plug :dispatch

    get "/page" do
      conn
      |> Plug.Conn.delete_resp_header("cache-control")
      |> send_resp(200, "some content")
    end
  end

  describe "call/2" do
    test "response is cached", %{test: test} do
      conn = conn(:get, "/page?#{URI.encode_www_form(to_string(test))}")
      request = {"GET", Plug.Conn.request_url(conn), [], ""}

      :telemetry.attach(test, @miss_telemetry_event, fn _, _, _, _ ->
        send(self(), {:telemetry_event, @miss_telemetry_event})
      end, nil)

      Router.call(conn, [])
      :timer.sleep(10)

      assert {:fresh, _} = :http_cache.get(request, store: :http_cache_store_process)
      assert_receive {:telemetry_event, @miss_telemetry_event}
    end

    test "cached content is served", %{test: test} do
      conn = conn(:get, "/page?#{URI.encode_www_form(to_string(test))}")

      :telemetry.attach(test, @hit_telemetry_event, fn _, _, _, _ ->
        send(self(), {:telemetry_event, @hit_telemetry_event})
      end, nil)

      Router.call(conn, [])
      :timer.sleep(10)
      conn = Router.call(conn, [])

      assert_receive {:telemetry_event, @hit_telemetry_event}
      assert conn.status == 200
      assert [_] = Plug.Conn.get_resp_header(conn, "age")
      assert conn.resp_body == "some content"
    end
  end

  describe "set_alternate_keys/2" do
    test "alternate key is used to invalidate entry", %{test: test} do
      conn = conn(:get, "/page?#{URI.encode_www_form(to_string(test))}")

      conn
      |> PlugHTTPCache.set_alternate_keys(:some_alt_key)
      |> PlugHTTPCache.set_alternate_keys([:some_other_alt_key])
      |> Router.call([])

      :timer.sleep(10)

      :http_cache.invalidate_by_alternate_key(:some_alt_key, store: :http_cache_store_process)
      conn = Router.call(conn, [])

      assert Plug.Conn.get_resp_header(conn, "age") == []
    end
  end
end
