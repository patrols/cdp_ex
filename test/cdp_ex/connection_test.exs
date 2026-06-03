defmodule CDPEx.ConnectionTest do
  use ExUnit.Case, async: true

  alias CDPEx.Connection
  alias CDPEx.FakeCDP

  setup do
    # The test process owns linked connections (via start_link), so it must trap
    # exits — exactly as a supervisor would. Without this, a test that drops a
    # socket sends its {:shutdown, {:ws_closed, _}} exit down the link and kills
    # whatever async sibling test is running, producing flaky, misattributed
    # failures.
    Process.flag(:trap_exit, true)

    {:ok, server} = FakeCDP.start()
    {:ok, conn} = Connection.start_link(server.url)
    assert_receive {:fake_cdp_connected, fake}, 2_000

    on_exit(fn ->
      # The conn is linked to the test process; ExUnit exits that process with
      # :shutdown, which can be racing this teardown. Tolerate an already-dying
      # process rather than letting the stop exit propagate as a test failure.
      try do
        if Process.alive?(conn), do: Connection.close(conn)
      catch
        :exit, _ -> :ok
      end
    end)

    %{conn: conn, fake: fake}
  end

  test "matches a reply to its caller", %{conn: conn, fake: fake} do
    task = Task.async(fn -> Connection.call(conn, "Page.enable", %{}) end)
    assert_receive {:fake_cdp_recv, ^fake, %{"id" => id, "method" => "Page.enable"}}, 2_000
    FakeCDP.send_text(fake, ~s({"id":#{id},"result":{"ok":true}}))
    assert {:ok, %{"ok" => true}} = Task.await(task)
  end

  test "call/5 with an :infinity timeout doesn't crash the connection", %{conn: conn, fake: fake} do
    ref = Process.monitor(conn)
    task = Task.async(fn -> Connection.call(conn, "Slow.op", %{}, :infinity) end)
    assert_receive {:fake_cdp_recv, ^fake, %{"id" => id, "method" => "Slow.op"}}, 2_000
    # Arming the timer is where Process.send_after(:infinity) would have raised.
    refute_received {:DOWN, ^ref, :process, ^conn, _}
    FakeCDP.send_text(fake, ~s({"id":#{id},"result":{"ok":true}}))
    assert {:ok, %{"ok" => true}} = Task.await(task)
  end

  test "await_event/4 with an :infinity timeout doesn't crash the connection", %{conn: conn} do
    ref = Process.monitor(conn)
    spawn(fn -> Connection.await_event(conn, fn _ -> false end, :infinity) end)
    Process.sleep(50)
    refute_received {:DOWN, ^ref, :process, ^conn, _}
    assert Process.alive?(conn)
  end

  test "stops when a linked owner exits (so terminate/2 closes the socket)" do
    # Connection traps exits; an owner's death must stop it rather than leave an
    # orphaned open socket. Driven directly — the handler doesn't read state.
    assert {:stop, :boom, %Connection{}} =
             Connection.handle_info({:EXIT, self(), :boom}, %Connection{})
  end

  test "an owner exit with :normal stops the connection quietly" do
    assert {:stop, :normal, %Connection{}} =
             Connection.handle_info({:EXIT, self(), :normal}, %Connection{})
  end

  test "call/5 with a negative (elapsed) timeout fires immediately, not a crash", %{conn: conn} do
    ref = Process.monitor(conn)
    # Process.send_after rejects negatives; arm_timeout clamps to an immediate 0.
    assert {:error, {:timeout, "Late.op"}} = Connection.call(conn, "Late.op", %{}, -1)
    refute_received {:DOWN, ^ref, :process, ^conn, _}
  end

  test "close/1 fails an in-flight caller with {:ws_closed, _}, not :noproc", %{
    conn: conn,
    fake: fake
  } do
    # terminate/2 drains pending callers with the precise {:ws_closed, _} shape
    # rather than letting them fall back to :noproc from the dying process.
    task = Task.async(fn -> Connection.call(conn, "Hang.forever", %{}) end)
    assert_receive {:fake_cdp_recv, ^fake, %{"method" => "Hang.forever"}}, 2_000
    Connection.close(conn)
    assert {:error, {:ws_closed, _}} = Task.await(task)
  end

  test "demultiplexes concurrent callers, even when replies arrive out of order", %{
    conn: conn,
    fake: fake
  } do
    a = Task.async(fn -> Connection.call(conn, "A", %{}) end)
    b = Task.async(fn -> Connection.call(conn, "B", %{}) end)
    c = Task.async(fn -> Connection.call(conn, "C", %{}) end)

    ids =
      for _ <- 1..3, into: %{} do
        assert_receive {:fake_cdp_recv, ^fake, %{"id" => id, "method" => m}}, 2_000
        {m, id}
      end

    # Reply in a deliberately scrambled order.
    FakeCDP.send_text(fake, ~s({"id":#{ids["C"]},"result":{"who":"C"}}))
    FakeCDP.send_text(fake, ~s({"id":#{ids["A"]},"result":{"who":"A"}}))
    FakeCDP.send_text(fake, ~s({"id":#{ids["B"]},"result":{"who":"B"}}))

    assert {:ok, %{"who" => "A"}} = Task.await(a)
    assert {:ok, %{"who" => "B"}} = Task.await(b)
    assert {:ok, %{"who" => "C"}} = Task.await(c)
  end

  test "wraps a CDP error reply with the originating method", %{conn: conn, fake: fake} do
    task = Task.async(fn -> Connection.call(conn, "Bad.method", %{}) end)
    assert_receive {:fake_cdp_recv, ^fake, %{"id" => id}}, 2_000
    FakeCDP.send_text(fake, ~s({"id":#{id},"error":{"code":-32601,"message":"not found"}}))

    assert {:error, {:cdp_error, "Bad.method", %{"code" => -32_601, "message" => "not found"}}} =
             Task.await(task)
  end

  test "times out a call that never gets a reply", %{conn: conn, fake: fake} do
    task = Task.async(fn -> Connection.call(conn, "Slow", %{}, 100) end)
    assert_receive {:fake_cdp_recv, ^fake, %{"method" => "Slow"}}, 2_000
    assert {:error, {:timeout, "Slow"}} = Task.await(task)
  end

  test "routes an event to a subscriber", %{conn: conn, fake: fake} do
    :ok = Connection.subscribe(conn, "Page.lifecycleEvent")
    FakeCDP.send_text(fake, ~s({"method":"Page.lifecycleEvent","params":{"name":"load"}}))

    assert_receive {:cdp_event, ^conn, "Page.lifecycleEvent", %{"name" => "load"}, nil}, 2_000
  end

  test ":all subscribers receive every event", %{conn: conn, fake: fake} do
    :ok = Connection.subscribe(conn, :all)
    FakeCDP.send_text(fake, ~s({"method":"Network.requestWillBeSent","params":{"x":1}}))

    assert_receive {:cdp_event, ^conn, "Network.requestWillBeSent", %{"x" => 1}, nil}, 2_000
  end

  test "demultiplexes two sessions' replies on one connection", %{conn: conn, fake: fake} do
    a = Task.async(fn -> Connection.call(conn, "Page.enable", %{}, 2_000, session_id: "A") end)
    b = Task.async(fn -> Connection.call(conn, "Page.enable", %{}, 2_000, session_id: "B") end)

    ids =
      for _ <- 1..2, into: %{} do
        assert_receive {:fake_cdp_recv, ^fake, %{"id" => id, "sessionId" => sid}}, 2_000
        {sid, id}
      end

    # Reply scrambled, each tagged with its own session.
    FakeCDP.send_text(fake, ~s({"id":#{ids["B"]},"sessionId":"B","result":{"who":"B"}}))
    FakeCDP.send_text(fake, ~s({"id":#{ids["A"]},"sessionId":"A","result":{"who":"A"}}))

    assert {:ok, %{"who" => "A"}} = Task.await(a)
    assert {:ok, %{"who" => "B"}} = Task.await(b)
  end

  test "events carry their sessionId to subscribers", %{conn: conn, fake: fake} do
    :ok = Connection.subscribe(conn, "Page.lifecycleEvent")

    FakeCDP.send_text(
      fake,
      ~s({"method":"Page.lifecycleEvent","sessionId":"A","params":{"name":"load"}})
    )

    assert_receive {:cdp_event, ^conn, "Page.lifecycleEvent", %{"name" => "load"}, "A"}, 2_000
  end

  test "await_event with a session gate ignores other sessions", %{conn: conn, fake: fake} do
    # A waiter scoped to session A must NOT resolve on a matching event from B.
    task =
      Task.async(fn -> Connection.await_event(conn, &(&1["name"] == "x"), 300, session_id: "A") end)

    FakeCDP.send_text(
      fake,
      ~s({"method":"Page.lifecycleEvent","sessionId":"B","params":{"name":"x"}})
    )

    assert {:error, {:timeout, :await_event}} = Task.await(task)

    # The same matcher resolves when the event is from session A.
    task2 =
      Task.async(fn ->
        Connection.await_event(conn, &(&1["name"] == "x"), 2_000, session_id: "A")
      end)

    FakeCDP.send_text(
      fake,
      ~s({"method":"Page.lifecycleEvent","sessionId":"A","params":{"name":"x"}})
    )

    assert :ok = Task.await(task2)
  end

  test "await_event resolves when a matching event arrives", %{conn: conn, fake: fake} do
    task =
      Task.async(fn ->
        Connection.await_event(conn, &(&1["name"] == "networkAlmostIdle"), 2_000)
      end)

    # A non-matching event first, then the match.
    FakeCDP.send_text(fake, ~s({"method":"Page.lifecycleEvent","params":{"name":"load"}}))

    FakeCDP.send_text(
      fake,
      ~s({"method":"Page.lifecycleEvent","params":{"name":"networkAlmostIdle"}})
    )

    assert :ok = Task.await(task)
  end

  test "await_event times out when no event matches", %{conn: conn} do
    assert {:error, {:timeout, :await_event}} = Connection.await_event(conn, fn _ -> false end, 100)
  end

  test "answering a server ping leaves the connection usable", %{conn: conn, fake: fake} do
    FakeCDP.send_ping(fake, "ping-payload")

    # The connection must still serve a normal call after handling the ping.
    task = Task.async(fn -> Connection.call(conn, "Still.alive", %{}) end)
    assert_receive {:fake_cdp_recv, ^fake, %{"id" => id, "method" => "Still.alive"}}, 2_000
    FakeCDP.send_text(fake, ~s({"id":#{id},"result":{}}))
    assert {:ok, %{}} = Task.await(task)
  end

  test "an abrupt socket drop fails pending callers and stops the connection", %{
    conn: conn,
    fake: fake
  } do
    ref = Process.monitor(conn)
    task = Task.async(fn -> Connection.call(conn, "Hang", %{}, 5_000) end)
    assert_receive {:fake_cdp_recv, ^fake, %{"method" => "Hang"}}, 2_000

    FakeCDP.hard_close(fake)

    assert {:error, {:ws_closed, _}} = Task.await(task)
    assert_receive {:DOWN, ^ref, :process, ^conn, {:shutdown, {:ws_closed, _}}}, 2_000
  end

  test "calling an already-stopped connection returns :noproc", %{conn: conn} do
    Connection.close(conn)
    # Give the stop a beat to land.
    ref = Process.monitor(conn)
    assert_receive {:DOWN, ^ref, :process, ^conn, _}, 2_000
    assert {:error, :noproc} = Connection.call(conn, "Page.enable", %{})
  end

  test "a graceful peer close frame fails pending callers and stops the connection", %{
    conn: conn,
    fake: fake
  } do
    ref = Process.monitor(conn)
    task = Task.async(fn -> Connection.call(conn, "Hang", %{}, 5_000) end)
    assert_receive {:fake_cdp_recv, ^fake, %{"method" => "Hang"}}, 2_000

    # A graceful WebSocket close (opcode 0x8) — not a raw TCP drop — must still
    # tear the connection down rather than leaving callers to time out.
    FakeCDP.close(fake)

    assert {:error, {:ws_closed, _}} = Task.await(task)
    assert_receive {:DOWN, ^ref, :process, ^conn, {:shutdown, {:ws_closed, _}}}, 2_000
  end

  test "a misbehaving matcher (throw/exit) is isolated and cannot crash the connection", %{
    conn: conn,
    fake: fake
  } do
    ref = Process.monitor(conn)

    throwing = Task.async(fn -> Connection.await_event(conn, fn _ -> throw(:boom) end, 300) end)
    exiting = Task.async(fn -> Connection.await_event(conn, fn _ -> exit(:boom) end, 300) end)

    # Delivering an event runs both matchers inside the connection process. Without
    # safe_match catching throw/exit, the first one would take the socket owner down.
    FakeCDP.send_text(fake, ~s({"method":"Page.lifecycleEvent","params":{"name":"load"}}))

    assert {:error, {:timeout, :await_event}} = Task.await(throwing)
    assert {:error, {:timeout, :await_event}} = Task.await(exiting)
    refute_received {:DOWN, ^ref, :process, ^conn, _}

    # The connection survived both and still serves a normal call.
    task = Task.async(fn -> Connection.call(conn, "Still.alive", %{}) end)
    assert_receive {:fake_cdp_recv, ^fake, %{"id" => id, "method" => "Still.alive"}}, 2_000
    FakeCDP.send_text(fake, ~s({"id":#{id},"result":{}}))
    assert {:ok, %{}} = Task.await(task)
  end

  test "a subscriber that dies without unsubscribing is pruned, not leaked", %{conn: conn} do
    parent = self()

    sub =
      spawn(fn ->
        :ok = Connection.subscribe(conn, "Page.lifecycleEvent")
        :ok = Connection.subscribe(conn, :all)
        send(parent, :subscribed)

        receive do
          :die -> :ok
        end
      end)

    assert_receive :subscribed, 2_000

    # The connection monitors the subscriber and tracks it in both sets.
    state = :sys.get_state(conn)
    assert Map.has_key?(state.monitors, sub)
    assert MapSet.member?(state.all_subscribers, sub)
    assert MapSet.member?(Map.get(state.subscribers, "Page.lifecycleEvent", MapSet.new()), sub)

    # Kill it without unsubscribing; the connection's :DOWN handler must prune it
    # from every subscription set and drop the monitor.
    Process.exit(sub, :kill)

    eventually(fn ->
      s = :sys.get_state(conn)

      not Map.has_key?(s.monitors, sub) and
        not MapSet.member?(s.all_subscribers, sub) and
        not MapSet.member?(Map.get(s.subscribers, "Page.lifecycleEvent", MapSet.new()), sub)
    end)
  end

  test "unsubscribing from the last method releases the monitor", %{conn: conn} do
    :ok = Connection.subscribe(conn, "A")
    :ok = Connection.subscribe(conn, :all)
    assert Map.has_key?(:sys.get_state(conn).monitors, self())

    # Still subscribed to :all, so the monitor stays.
    :ok = Connection.unsubscribe(conn, "A")
    assert Map.has_key?(:sys.get_state(conn).monitors, self())

    # No subscriptions left: the monitor is released.
    :ok = Connection.unsubscribe(conn, :all)
    refute Map.has_key?(:sys.get_state(conn).monitors, self())
  end

  test "an owner death during the upgrade brings the connection down promptly" do
    # A stalling server accepts the socket but never finishes the upgrade, so the
    # connection sits in recv_upgrade. With trap_exit deferred past the handshake,
    # the owner's death (via the link) aborts the connect at once. The regressed
    # version trapped during the handshake and swallowed the {:EXIT}, lingering
    # until the (here generous) upgrade timeout.
    {:ok, server} = FakeCDP.start_stalling()

    owner =
      spawn(fn ->
        Connection.start_link(server.url, upgrade_timeout: 10_000)
        Process.sleep(:infinity)
      end)

    assert_receive {:fake_cdp_stalled, _fake}, 2_000
    Process.exit(owner, :kill)
    assert_receive {:fake_cdp_client_gone, _fake}, 2_000
  end

  test "a server ping then an abrupt drop stops the connection (never runs on a dead socket)", %{
    conn: conn,
    fake: fake
  } do
    # Exercises the ping → pong path on a failing socket. A failed pong write now
    # stops the connection (mirroring ws_send/2); and even if the write wins the
    # race before the drop, the close still tears it down. Either way it must not
    # be left running on a dead socket.
    ref = Process.monitor(conn)
    FakeCDP.send_ping(fake, "ka")
    FakeCDP.hard_close(fake)
    assert_receive {:DOWN, ^ref, :process, ^conn, {:shutdown, {:ws_closed, _}}}, 2_000
  end

  # Poll until `fun` returns true, or fail — for asserting an async state change
  # (here: the connection processing a subscriber's :DOWN) without a fixed sleep.
  defp eventually(fun, retries \\ 100) do
    cond do
      fun.() ->
        :ok

      retries > 0 ->
        Process.sleep(10)
        eventually(fun, retries - 1)

      true ->
        flunk("condition not met in time")
    end
  end
end
