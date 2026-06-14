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

  test "an unreachable endpoint is a discovery failure" do
    assert {:error, {:connect_discovery_failed, _}} = Connect.resolve("http://127.0.0.1:1")
  end

  test "a non-ws/http endpoint is a discovery failure" do
    assert {:error, {:connect_discovery_failed, {:invalid_endpoint, _}}} =
             Connect.resolve("ftp://nope")
  end
end
