defmodule CDPEx.ConnectTest do
  use ExUnit.Case, async: true

  alias CDPEx.Connect
  alias CDPEx.FixtureServer

  test "passes a ws:// endpoint through unchanged" do
    assert {:ok, "ws://host:9222/devtools/browser/x"} =
             Connect.resolve("ws://host:9222/devtools/browser/x")
  end

  test "passes a wss:// endpoint through unchanged" do
    assert {:ok, "wss://host/devtools/browser/x"} = Connect.resolve("wss://host/devtools/browser/x")
  end

  test "discovers via /json/version and derives host/port from the endpoint" do
    {:ok, %{url: base}} = FixtureServer.start()
    %URI{host: host, port: port} = URI.parse(base)

    # The fixture returns ws://127.0.0.1:1/...; the resolver must rewrite host/port
    # to the endpoint's, keeping only the discovered path.
    assert {:ok, ws} = Connect.resolve("http://#{host}:#{port}")
    assert ws == "ws://#{host}:#{port}/devtools/browser/FAKE-GUID"
  end

  test "discovery preserves the query string from webSocketDebuggerUrl" do
    {:ok, %{url: base}} = FixtureServer.start(json_version: :with_query)
    %URI{host: host, port: port} = URI.parse(base)

    assert {:ok, ws} = Connect.resolve("http://#{host}:#{port}")
    assert ws == "ws://#{host}:#{port}/devtools/browser/GUID?token=abc"
  end

  test "a non-200 /json/version is a discovery failure carrying the status" do
    {:ok, %{url: base}} = FixtureServer.start(json_version: :server_error)
    %URI{host: host, port: port} = URI.parse(base)

    assert {:error, {:connect_discovery_failed, {:http_status, 500}}} =
             Connect.resolve("http://#{host}:#{port}")
  end

  test "a /json/version without webSocketDebuggerUrl is a discovery failure" do
    {:ok, %{url: base}} = FixtureServer.start(json_version: :no_key)
    %URI{host: host, port: port} = URI.parse(base)

    assert {:error, {:connect_discovery_failed, _}} = Connect.resolve("http://#{host}:#{port}")
  end

  test "a non-string webSocketDebuggerUrl is a discovery failure, not a caller crash" do
    {:ok, %{url: base}} = FixtureServer.start(json_version: :non_string)
    %URI{host: host, port: port} = URI.parse(base)

    assert {:error, {:connect_discovery_failed, _}} = Connect.resolve("http://#{host}:#{port}")
  end

  test "an oversized /json/version body is rejected by the size cap" do
    {:ok, %{url: base}} = FixtureServer.start(json_version: :oversized)
    %URI{host: host, port: port} = URI.parse(base)

    assert {:error, {:connect_discovery_failed, :discovery_body_too_large}} =
             Connect.resolve("http://#{host}:#{port}")
  end

  test "a hanging /json/version trips the discovery timeout" do
    {:ok, %{url: base}} = FixtureServer.start(json_version: :hang)
    %URI{host: host, port: port} = URI.parse(base)

    assert {:error, {:connect_discovery_failed, :discovery_timeout}} =
             Connect.resolve("http://#{host}:#{port}", [], timeout: 50)
  end

  test "an :infinity timeout discovers without a deadline" do
    {:ok, %{url: base}} = FixtureServer.start()
    %URI{host: host, port: port} = URI.parse(base)

    assert Connect.resolve("http://#{host}:#{port}", [], timeout: :infinity) ==
             {:ok, "ws://#{host}:#{port}/devtools/browser/FAKE-GUID"}
  end

  test "an unreachable endpoint is a discovery failure" do
    assert {:error, {:connect_discovery_failed, _}} = Connect.resolve("http://127.0.0.1:1")
  end

  test "a non-ws/http endpoint is a discovery failure" do
    assert {:error, {:connect_discovery_failed, {:invalid_endpoint, _}}} =
             Connect.resolve("ftp://nope")
  end

  test "a host-less ws:// endpoint is a structured failure, not a later ArgumentError" do
    assert {:error, {:connect_discovery_failed, {:invalid_endpoint, _}}} =
             Connect.resolve("ws:///devtools/browser/x")
  end

  describe "CDPEx.connect/2 :discovery_timeout" do
    # The fixture's ws:// URL serves a page, not an upgrade, so getting as far as
    # {:ws_upgrade, _} means discovery itself succeeded.
    test "nil, :infinity and the largest integer discover the endpoint" do
      {:ok, %{url: base}} = FixtureServer.start()

      for timeout <- [nil, :infinity, 4_294_967_295] do
        assert {:error, {:ws_upgrade, _}} = CDPEx.connect(base, discovery_timeout: timeout)
      end
    end

    test "an integer bounds discovery" do
      {:ok, %{url: base}} = FixtureServer.start(json_version: :hang)

      for timeout <- [0, 50] do
        {elapsed_us, result} =
          :timer.tc(fn -> CDPEx.connect(base, discovery_timeout: timeout) end)

        assert result == {:error, {:connect_discovery_failed, :discovery_timeout}}
        assert elapsed_us < 2_000_000
      end
    end

    test "any other value raises in the caller" do
      for timeout <- ["5000", -1, 4_294_967_296, 1.5, :never] do
        assert_raise ArgumentError,
                     "invalid :discovery_timeout #{inspect(timeout)} " <>
                       "(expected integer ms in 0..4_294_967_295 or :infinity)",
                     fn -> CDPEx.connect("http://127.0.0.1:1", discovery_timeout: timeout) end
      end
    end
  end
end
