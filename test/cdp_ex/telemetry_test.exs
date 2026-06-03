defmodule CDPEx.TelemetryTest do
  # NOT async: :telemetry handlers are VM-global, so an async run would let this module's
  # handler receive [:cdp_ex, :navigate, ...] events from other concurrent tests (e.g.
  # PageTest navigating the same URL), making assert_receive/refute_received nondeterministic.
  use ExUnit.Case, async: false

  alias CDPEx.Connection
  alias CDPEx.FakeCDP
  alias CDPEx.Page
  alias CDPEx.Telemetry

  setup do
    # The test process owns the linked connection; trap exits and tolerate an
    # already-dying conn in teardown (same as ConnectionTest / PageTest).
    Process.flag(:trap_exit, true)

    {:ok, server} = FakeCDP.start()
    {:ok, conn} = Connection.start_link(server.url)
    assert_receive {:fake_cdp_connected, fake}, 2_000

    on_exit(fn ->
      try do
        if Process.alive?(conn), do: Connection.close(conn)
      catch
        :exit, _ -> :ok
      end
    end)

    # navigate/3 only touches page.conn, so a dummy browser pid is fine here.
    %{
      page: %Page{browser: self(), conn: conn, target_id: "T", session_id: nil},
      conn: conn,
      fake: fake
    }
  end

  describe "navigate/3 span" do
    test "emits :start (url) then :stop (duration + url/status/final_url)", %{
      page: page,
      fake: fake
    } do
      attach([[:cdp_ex, :navigate, :start], [:cdp_ex, :navigate, :stop]])

      task = Task.async(fn -> Page.navigate(page, "http://example.test/", wait_until: :none) end)
      assert_receive {:fake_cdp_recv, ^fake, %{"id" => id, "method" => "Page.navigate"}}, 2_000
      FakeCDP.send_text(fake, ~s({"id":#{id},"result":{}}))
      assert {:ok, %Page{}} = Task.await(task)

      assert_receive {:telemetry, [:cdp_ex, :navigate, :start], _measurements,
                      %{url: "http://example.test/"}}

      assert_receive {:telemetry, [:cdp_ex, :navigate, :stop], %{duration: duration}, meta}
      assert duration > 0
      # :telemetry.span also injects :telemetry_span_context, so match the subset.
      assert %{url: "http://example.test/", status: nil, final_url: nil} = meta
    end

    test "a navigation error flows through :stop (with :error), not :exception", %{
      page: page,
      fake: fake
    } do
      attach([[:cdp_ex, :navigate, :stop], [:cdp_ex, :navigate, :exception]])

      task = Task.async(fn -> Page.navigate(page, "http://example.test/", wait_until: :none) end)
      assert_receive {:fake_cdp_recv, ^fake, %{"id" => id, "method" => "Page.navigate"}}, 2_000
      FakeCDP.send_text(fake, ~s({"id":#{id},"result":{"errorText":"net::ERR_NAME_NOT_RESOLVED"}}))
      assert {:error, {:navigate, _}} = Task.await(task)

      assert_receive {:telemetry, [:cdp_ex, :navigate, :stop], _, %{error: {:navigate, _}}}
      refute_received {:telemetry, [:cdp_ex, :navigate, :exception], _, _}
    end

    test "response: true populates :stop status + final_url", %{page: page, conn: conn, fake: fake} do
      attach([[:cdp_ex, :navigate, :stop]])

      task = Task.async(fn -> Page.navigate(page, "http://example.test/", response: true) end)

      assert_receive {:fake_cdp_recv, ^fake, %{"id" => nid, "method" => "Network.enable"}}, 2_000
      FakeCDP.send_text(fake, ~s({"id":#{nid},"result":{}}))

      wait_until_subscribed(conn, task.pid, "Network.responseReceived")
      wait_until_subscribed(conn, task.pid, "Page.lifecycleEvent")

      assert_receive {:fake_cdp_recv, ^fake, %{"id" => navid, "method" => "Page.navigate"}}, 2_000
      FakeCDP.send_text(fake, ~s({"id":#{navid},"result":{"frameId":"F","loaderId":"L"}}))

      FakeCDP.send_text(
        fake,
        ~s({"method":"Network.responseReceived","params":{"type":"Document","loaderId":"L","frameId":"F","response":{"status":200,"url":"http://example.test/landed"}}})
      )

      FakeCDP.send_text(
        fake,
        ~s({"method":"Page.lifecycleEvent","params":{"name":"networkAlmostIdle"}})
      )

      assert {:ok, %Page{}, %{status: 200}} = Task.await(task)

      assert_receive {:telemetry, [:cdp_ex, :navigate, :stop], _,
                      %{status: 200, final_url: "http://example.test/landed"}}
    end

    test "an invalid :wait_until raises and emits :exception, not :stop", %{page: page} do
      attach([[:cdp_ex, :navigate, :exception], [:cdp_ex, :navigate, :stop]])

      assert_raise ArgumentError, fn ->
        Page.navigate(page, "http://example.test/", wait_until: :bogus)
      end

      assert_receive {:telemetry, [:cdp_ex, :navigate, :exception], _measurements,
                      %{url: "http://example.test/", kind: :error}}

      refute_received {:telemetry, [:cdp_ex, :navigate, :stop], _, _}
    end
  end

  describe "execute helpers" do
    test "page/2 emits [:cdp_ex, :page, stage] with system_time + metadata" do
      attach([[:cdp_ex, :page, :start], [:cdp_ex, :page, :stop]])

      Telemetry.page(:start, %{target_id: "T", transport: :dedicated})
      assert_receive {:telemetry, [:cdp_ex, :page, :start], %{system_time: t}, meta}
      assert is_integer(t)
      assert meta == %{target_id: "T", transport: :dedicated}

      Telemetry.page(:stop, %{target_id: "T", transport: :session})
      assert_receive {:telemetry, [:cdp_ex, :page, :stop], _, %{transport: :session}}
    end

    test "error/2 emits [:cdp_ex, :error] with reason + context" do
      attach([[:cdp_ex, :error]])

      Telemetry.error(:boom, :ws_closed)

      assert_receive {:telemetry, [:cdp_ex, :error], %{system_time: t},
                      %{reason: :boom, context: :ws_closed}}

      assert is_integer(t)
    end

    test "emitting with no handler attached is a no-op (doesn't raise)" do
      assert :ok = Telemetry.page(:start, %{target_id: "T", transport: :dedicated})
      assert :ok = Telemetry.error(:boom, :chrome_exited)
    end
  end

  # Attach a handler forwarding each event to the test process; detach on exit. A named
  # (module) handler avoids :telemetry's local/anonymous-handler warning; the config (4th
  # arg) carries the test pid.
  defp attach(events) do
    id = "telemetry-test-#{System.unique_integer([:positive])}"
    :telemetry.attach_many(id, events, &__MODULE__.forward/4, self())
    on_exit(fn -> :telemetry.detach(id) end)
  end

  @doc false
  def forward(event, measurements, metadata, test_pid) do
    send(test_pid, {:telemetry, event, measurements, metadata})
  end

  # Poll until `pid` is registered as a `method` subscriber on `conn` (no send/subscribe
  # race for the response-capture path).
  defp wait_until_subscribed(conn, pid, method, retries \\ 100) do
    cond do
      MapSet.member?(Map.get(:sys.get_state(conn).subscribers, method, MapSet.new()), pid) ->
        :ok

      retries == 0 ->
        flunk("subscriber #{method} not registered in time")

      true ->
        Process.sleep(10) && wait_until_subscribed(conn, pid, method, retries - 1)
    end
  end
end
