defmodule CDPEx.PageTest do
  use ExUnit.Case, async: true

  alias CDPEx.Connection
  alias CDPEx.FakeCDP
  alias CDPEx.Page

  setup do
    # The test process owns the linked connection (via start_link), so trap exits
    # and tolerate an already-dying conn in teardown — same as ConnectionTest.
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

    %{
      page: %Page{browser: self(), conn: conn, target_id: "T", session_id: nil},
      conn: conn,
      fake: fake
    }
  end

  describe "wait_for_navigation/2" do
    test "resolves only on a matching Page.lifecycleEvent — not another method or name", %{
      page: page,
      conn: conn,
      fake: fake
    } do
      task = Task.async(fn -> Page.wait_for_navigation(page, wait_until: :load, timeout: 2_000) end)
      wait_until_subscribed(conn, task.pid)

      # The old generic await_event matcher (`&(&1["name"] == name)`) would have been
      # tripped by either of these — a non-lifecycle method whose params carry the
      # name, and a lifecycle event for a *different* milestone. The method-keyed
      # subscription + name-pinned receive must ignore both.
      FakeCDP.send_text(fake, ~s({"method":"Runtime.bindingCalled","params":{"name":"load"}}))
      FakeCDP.send_text(fake, ~s({"method":"Page.lifecycleEvent","params":{"name":"init"}}))

      refute Task.yield(task, 200), "wait_for_navigation resolved on a non-matching event"

      # The real milestone resolves it.
      FakeCDP.send_text(fake, ~s({"method":"Page.lifecycleEvent","params":{"name":"load"}}))
      assert :ok = Task.await(task)
    end

    test "times out when the milestone never arrives", %{page: page} do
      assert {:error, :timeout} = Page.wait_for_navigation(page, wait_until: :load, timeout: 100)
    end

    test ":none returns immediately without waiting", %{page: page} do
      assert :ok = Page.wait_for_navigation(page, wait_until: :none)
    end

    test "raises on an unknown :wait_until value", %{page: page} do
      assert_raise ArgumentError, ~r/invalid :wait_until :bogus/, fn ->
        Page.wait_for_navigation(page, wait_until: :bogus)
      end
    end
  end

  # Poll until `pid` is registered as a Page.lifecycleEvent subscriber on `conn`, so
  # events sent afterward are guaranteed to be delivered to it (no send/subscribe race).
  defp wait_until_subscribed(conn, pid, retries \\ 100) do
    subs = Map.get(:sys.get_state(conn).subscribers, "Page.lifecycleEvent", MapSet.new())

    cond do
      MapSet.member?(subs, pid) ->
        :ok

      retries == 0 ->
        flunk("subscriber not registered in time")

      true ->
        Process.sleep(10)
        wait_until_subscribed(conn, pid, retries - 1)
    end
  end
end
