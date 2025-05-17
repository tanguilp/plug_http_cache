defmodule PlugHttpCacheTest do
  use ExUnit.Case

  import Plug.Test

  @hit_telemetry_event [:plug_http_cache, :hit]
  @miss_telemetry_event [:plug_http_cache, :miss]

  defmodule Router do
    use Plug.Router

    plug(PlugHTTPCache, %{store: :http_cache_store_process})
    plug(:match)
    plug(:dispatch)

    get "/page" do
      conn
      |> Plug.Conn.delete_resp_header("cache-control")
      |> send_resp(200, "some content")
    end
  end

  Application.put_env(:phoenix, Module.concat(__MODULE__, EndpointForRevalidate), [])

  defmodule EndpointForRevalidate do
    use Phoenix.Endpoint, otp_app: :phoenix

    def init(opts), do: opts

    def call(conn, _opts) do
      PlugHttpCacheTest.RouterForRevalidate.call(
        conn,
        PlugHttpCacheTest.RouterForRevalidate.init([])
      )
    end
  end

  defmodule RouterForRevalidate do
    # We need a global state to test support for `stale-while-revalidate`, because the revalidate
    # request is performed in another process. `http_cache_store_memory` provides with that
    use Plug.Router

    plug(PlugHTTPCache, %{store: :http_cache_store_memory})
    plug(:match)
    plug(:dispatch)

    get "/stale/while/revalidate" do
      conn
      |> Plug.Conn.put_resp_header("cache-control", "max-age=0, stale-while-revalidate=60")
      |> send_resp(200, "some content")
    end
  end

  setup_all do
    EndpointForRevalidate.start_link()
    :ok
  end

  describe "call/2" do
    test "response is cached", %{test: test} do
      conn = conn(:get, "/page?#{URI.encode_www_form(to_string(test))}")
      request = {"GET", Plug.Conn.request_url(conn), [], ""}

      :telemetry.attach(
        test,
        @miss_telemetry_event,
        fn _, _, _, _ ->
          send(self(), {:telemetry_event, @miss_telemetry_event})
        end,
        nil
      )

      Router.call(conn, [])

      assert {:fresh, _} = :http_cache.get(request, %{store: :http_cache_store_process})
      assert_receive {:telemetry_event, @miss_telemetry_event}
    end

    test "cached content is served", %{test: test} do
      conn = conn(:get, "/page?#{URI.encode_www_form(to_string(test))}")

      :telemetry.attach(
        test,
        @hit_telemetry_event,
        fn _, _, _, _ ->
          send(self(), {:telemetry_event, @hit_telemetry_event})
        end,
        nil
      )

      Router.call(conn, [])
      conn = Router.call(conn, [])

      assert_receive {:telemetry_event, @hit_telemetry_event}
      assert conn.status == 200
      assert [_] = Plug.Conn.get_resp_header(conn, "age")
      assert conn.resp_body == "some content"
    end

    test "non-cacheable content is not cached", %{test: test} do
      conn =
        conn(:get, "/page?#{URI.encode_www_form(to_string(test))}")
        |> Plug.Conn.put_req_header("cache-control", "no-store")

      request = {"GET", Plug.Conn.request_url(conn), [], ""}

      :telemetry.attach(
        test,
        @miss_telemetry_event,
        fn _, _, _, _ ->
          send(self(), {:telemetry_event, @miss_telemetry_event})
        end,
        nil
      )

      Router.call(conn, [])

      assert :http_cache.get(request, %{store: :http_cache_store_process}) == :miss
      assert_receive {:telemetry_event, @miss_telemetry_event}
    end

    test "stale-while-revalidate is supported" do
      conn = conn(:get, "/stale/while/revalidate")

      ref = :telemetry_test.attach_event_handlers(self(), [[:http_cache, :cache]])

      EndpointForRevalidate.call(conn, [])
      EndpointForRevalidate.call(conn, [])

      assert_receive {[:http_cache, :cache], ^ref, _, %{cacheable: true}}
      assert_receive {[:http_cache, :cache], ^ref, _, %{cacheable: true}}
    end

    test "client max-stale is discarded" do
      # If it was not, then the user would be able to create infinite cycles because we use
      # `max-stale=0` when revalidating to prevent receiving again a stale response which will
      # trigger another revalidation and so on

      conn =
        :get
        |> conn("/stale/while/revalidate")
        |> Plug.Conn.put_req_header("cache-control", "max-stale=3600")

      ref = :telemetry_test.attach_event_handlers(self(), [[:http_cache, :cache]])

      EndpointForRevalidate.call(conn, [])

      :timer.sleep(2_000)

      {_, messages} = :erlang.process_info(self(), :messages)

      # An infinite cycle would create tons of telemetry messages
      assert length(messages) < 100
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

      :http_cache.invalidate_by_alternate_key(:some_alt_key, %{store: :http_cache_store_process})
      conn = Router.call(conn, [])

      assert Plug.Conn.get_resp_header(conn, "age") == []
    end
  end
end
