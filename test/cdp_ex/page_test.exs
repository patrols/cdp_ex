defmodule CDPEx.PageTest do
  use ExUnit.Case, async: true

  alias CDPEx.Connection
  alias CDPEx.FakeCDP
  alias CDPEx.Page

  @network_methods ["Network.requestWillBeSent", "Network.responseReceived"]

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

  describe "authenticate/4 source validation" do
    # A bad :source short-circuits before Browser.authenticate, so these never touch
    # the (test-process) browser — they exercise the boundary guard in isolation.
    test "rejects an unknown :source atom", %{page: page} do
      assert {:error, {:invalid_source, :bogus}} =
               Page.authenticate(page, "u", "p", source: :bogus)
    end

    test "rejects a stringly-typed :source", %{page: page} do
      assert {:error, {:invalid_source, "proxy"}} =
               Page.authenticate(page, "u", "p", source: "proxy")
    end
  end

  describe "observe_network/2 + response_body/3" do
    test "subscribes the caller to both methods, then enables Network", %{
      page: page,
      conn: conn,
      fake: fake
    } do
      task = Task.async(fn -> Page.observe_network(page) end)

      # Subscription happens BEFORE the enable — both methods are registered while
      # the enable call is still in flight.
      for method <- @network_methods, do: wait_until_subscribed(conn, task.pid, method)

      assert_receive {:fake_cdp_recv, ^fake, %{"id" => id, "method" => "Network.enable"}}, 2_000
      FakeCDP.send_text(fake, ~s({"id":#{id},"result":{}}))

      assert :ok = Task.await(task)
    end

    test "returns {:error, :noproc} when the connection is dead", %{page: page, conn: conn} do
      ref = Process.monitor(conn)
      Connection.close(conn)
      assert_receive {:DOWN, ^ref, :process, ^conn, _}, 2_000

      assert {:error, :noproc} = Page.observe_network(page)
    end

    test "stop_observing_network removes the caller's subscriptions", %{page: page, conn: conn} do
      for method <- @network_methods, do: Connection.subscribe(conn, method)
      for method <- @network_methods, do: assert(subscribed?(conn, self(), method))

      assert :ok = Page.stop_observing_network(page)

      for method <- @network_methods, do: refute(subscribed?(conn, self(), method))
    end

    test "response_body decodes a base64 body", %{page: page, fake: fake} do
      task = Task.async(fn -> Page.response_body(page, "REQ1") end)

      assert_receive {:fake_cdp_recv, ^fake,
                      %{
                        "id" => id,
                        "method" => "Network.getResponseBody",
                        "params" => %{"requestId" => "REQ1"}
                      }},
                     2_000

      body = Base.encode64("raw bytes")
      FakeCDP.send_text(fake, ~s({"id":#{id},"result":{"body":"#{body}","base64Encoded":true}}))
      assert {:ok, "raw bytes"} = Task.await(task)
    end

    test "response_body passes a plain (non-base64) body through", %{page: page, fake: fake} do
      task = Task.async(fn -> Page.response_body(page, "REQ1") end)
      assert_receive {:fake_cdp_recv, ^fake, %{"id" => id}}, 2_000
      FakeCDP.send_text(fake, ~s({"id":#{id},"result":{"body":"<html>","base64Encoded":false}}))
      assert {:ok, "<html>"} = Task.await(task)
    end

    test "response_body maps a CDP error to {:error, _}", %{page: page, fake: fake} do
      task = Task.async(fn -> Page.response_body(page, "REQ1") end)
      assert_receive {:fake_cdp_recv, ^fake, %{"id" => id}}, 2_000
      FakeCDP.send_text(fake, ~s({"id":#{id},"error":{"code":-32000,"message":"No data found"}}))
      assert {:error, {:cdp_error, "Network.getResponseBody", _}} = Task.await(task)
    end

    test "response_body reports an undecodable base64 body", %{page: page, fake: fake} do
      task = Task.async(fn -> Page.response_body(page, "REQ1") end)
      assert_receive {:fake_cdp_recv, ^fake, %{"id" => id}}, 2_000

      FakeCDP.send_text(
        fake,
        ~s({"id":#{id},"result":{"body":"!!!not base64!!!","base64Encoded":true}})
      )

      # The error carries the offending (undecodable) payload, not just a bare atom.
      assert {:error, {:invalid_response_body, "!!!not base64!!!"}} = Task.await(task)
    end

    test "observe_network rolls back its subscriptions when Network.enable fails", %{
      page: page,
      conn: conn,
      fake: fake
    } do
      # Run from a long-lived helper (not a Task that exits) so the post-rollback
      # subscription state reflects the rollback's unsubscribe — not the connection's
      # automatic prune of a dead subscriber.
      test = self()

      observer =
        spawn_link(fn ->
          send(test, {:observe_result, Page.observe_network(page)})

          receive do
            :stop -> :ok
          after
            5_000 -> :ok
          end
        end)

      for method <- @network_methods, do: wait_until_subscribed(conn, observer, method)

      assert_receive {:fake_cdp_recv, ^fake, %{"id" => id, "method" => "Network.enable"}}, 2_000
      FakeCDP.send_text(fake, ~s({"id":#{id},"error":{"code":-32000,"message":"boom"}}))

      assert_receive {:observe_result, {:error, {:cdp_error, "Network.enable", _}}}, 2_000

      # The enable failed, so both subscriptions were rolled back.
      for method <- @network_methods, do: refute(subscribed?(conn, observer, method))

      send(observer, :stop)
    end
  end

  describe "request interception" do
    test "enable_request_interception subscribes the caller and enables Fetch with patterns", %{
      page: page,
      conn: conn,
      fake: fake
    } do
      task = Task.async(fn -> Page.enable_request_interception(page) end)

      wait_until_subscribed(conn, task.pid, "Fetch.requestPaused")

      assert_receive {:fake_cdp_recv, ^fake,
                      %{"id" => id, "method" => "Fetch.enable", "params" => params}},
                     2_000

      assert params["patterns"] == [%{"urlPattern" => "*"}]
      FakeCDP.send_text(fake, ~s({"id":#{id},"result":{}}))
      assert :ok = Task.await(task)
    end

    test "continue_request maps options to Fetch.continueRequest params", %{page: page, fake: fake} do
      task =
        Task.async(fn ->
          Page.continue_request(page, "R1",
            url: "https://example.test/",
            method: "POST",
            headers: %{"X-Test" => "1"},
            post_data: "hello"
          )
        end)

      assert_receive {:fake_cdp_recv, ^fake,
                      %{"id" => id, "method" => "Fetch.continueRequest", "params" => params}},
                     2_000

      assert params["requestId"] == "R1"
      assert params["url"] == "https://example.test/"
      assert params["method"] == "POST"
      assert params["headers"] == [%{"name" => "X-Test", "value" => "1"}]
      assert params["postData"] == Base.encode64("hello")

      FakeCDP.send_text(fake, ~s({"id":#{id},"result":{}}))
      assert :ok = Task.await(task)
    end

    test "fulfill_request base64-encodes the body and defaults the status", %{
      page: page,
      fake: fake
    } do
      task = Task.async(fn -> Page.fulfill_request(page, "R1", body: "<h1>hi</h1>") end)

      assert_receive {:fake_cdp_recv, ^fake,
                      %{"id" => id, "method" => "Fetch.fulfillRequest", "params" => params}},
                     2_000

      assert params["requestId"] == "R1"
      assert params["responseCode"] == 200
      assert params["body"] == Base.encode64("<h1>hi</h1>")

      FakeCDP.send_text(fake, ~s({"id":#{id},"result":{}}))
      assert :ok = Task.await(task)
    end

    test "fail_request maps a known reason to its CDP string", %{page: page, fake: fake} do
      task = Task.async(fn -> Page.fail_request(page, "R1", reason: :aborted) end)

      assert_receive {:fake_cdp_recv, ^fake,
                      %{"id" => id, "method" => "Fetch.failRequest", "params" => params}},
                     2_000

      assert params == %{"requestId" => "R1", "errorReason" => "Aborted"}
      FakeCDP.send_text(fake, ~s({"id":#{id},"result":{}}))
      assert :ok = Task.await(task)
    end

    test "fail_request rejects an unknown reason before calling CDP", %{page: page} do
      assert {:error, {:invalid_error_reason, :bogus}} =
               Page.fail_request(page, "R1", reason: :bogus)
    end

    test "fail_request defaults the reason to :failed", %{page: page, fake: fake} do
      task = Task.async(fn -> Page.fail_request(page, "R1") end)

      assert_receive {:fake_cdp_recv, ^fake,
                      %{"id" => id, "method" => "Fetch.failRequest", "params" => params}},
                     2_000

      assert params == %{"requestId" => "R1", "errorReason" => "Failed"}
      FakeCDP.send_text(fake, ~s({"id":#{id},"result":{}}))
      assert :ok = Task.await(task)
    end

    test "continue_request with no options sends only the requestId", %{page: page, fake: fake} do
      task = Task.async(fn -> Page.continue_request(page, "R1") end)

      assert_receive {:fake_cdp_recv, ^fake,
                      %{"id" => id, "method" => "Fetch.continueRequest", "params" => params}},
                     2_000

      # put_present omits absent options — no leaked url/method/headers/postData keys.
      assert params == %{"requestId" => "R1"}
      FakeCDP.send_text(fake, ~s({"id":#{id},"result":{}}))
      assert :ok = Task.await(task)
    end

    test "fulfill_request with no options sends only requestId + default status", %{
      page: page,
      fake: fake
    } do
      task = Task.async(fn -> Page.fulfill_request(page, "R1") end)

      assert_receive {:fake_cdp_recv, ^fake,
                      %{"id" => id, "method" => "Fetch.fulfillRequest", "params" => params}},
                     2_000

      assert params == %{"requestId" => "R1", "responseCode" => 200}
      FakeCDP.send_text(fake, ~s({"id":#{id},"result":{}}))
      assert :ok = Task.await(task)
    end

    test "disable_request_interception unsubscribes the caller and disables Fetch", %{
      page: page,
      conn: conn,
      fake: fake
    } do
      test = self()

      caller =
        spawn_link(fn ->
          Connection.subscribe(conn, "Fetch.requestPaused")
          send(test, :subscribed)

          receive do
            :go -> :ok
          end

          send(test, {:disabled, Page.disable_request_interception(page)})

          receive do
            :stop -> :ok
          after
            5_000 -> :ok
          end
        end)

      assert_receive :subscribed, 2_000
      assert subscribed?(conn, caller, "Fetch.requestPaused")
      send(caller, :go)

      # disable unsubscribes (synchronously) then blocks on Fetch.disable.
      assert_receive {:fake_cdp_recv, ^fake, %{"id" => id, "method" => "Fetch.disable"}}, 2_000
      refute subscribed?(conn, caller, "Fetch.requestPaused")

      FakeCDP.send_text(fake, ~s({"id":#{id},"result":{}}))
      assert_receive {:disabled, :ok}, 2_000
      send(caller, :stop)
    end

    test "enable_request_interception rolls back the subscription when Fetch.enable fails", %{
      page: page,
      conn: conn,
      fake: fake
    } do
      test = self()

      observer =
        spawn_link(fn ->
          send(test, {:enable_result, Page.enable_request_interception(page)})

          receive do
            :stop -> :ok
          after
            5_000 -> :ok
          end
        end)

      wait_until_subscribed(conn, observer, "Fetch.requestPaused")

      assert_receive {:fake_cdp_recv, ^fake, %{"id" => id, "method" => "Fetch.enable"}}, 2_000
      FakeCDP.send_text(fake, ~s({"id":#{id},"error":{"code":-32000,"message":"boom"}}))

      assert_receive {:enable_result, {:error, {:cdp_error, "Fetch.enable", _}}}, 2_000
      refute subscribed?(conn, observer, "Fetch.requestPaused")

      send(observer, :stop)
    end

    test "fulfill_request maps :headers to responseHeaders", %{page: page, fake: fake} do
      task =
        Task.async(fn ->
          Page.fulfill_request(page, "R1", headers: %{"Content-Type" => "text/html"})
        end)

      assert_receive {:fake_cdp_recv, ^fake,
                      %{"id" => id, "method" => "Fetch.fulfillRequest", "params" => params}},
                     2_000

      assert params["responseHeaders"] == [%{"name" => "Content-Type", "value" => "text/html"}]
      FakeCDP.send_text(fake, ~s({"id":#{id},"result":{}}))
      assert :ok = Task.await(task)
    end

    test "continue_request accepts a keyword-list :headers", %{page: page, fake: fake} do
      task =
        Task.async(fn ->
          Page.continue_request(page, "R1", headers: [{"X-A", "1"}, {"X-B", "2"}])
        end)

      assert_receive {:fake_cdp_recv, ^fake,
                      %{"id" => id, "method" => "Fetch.continueRequest", "params" => params}},
                     2_000

      assert params["headers"] == [
               %{"name" => "X-A", "value" => "1"},
               %{"name" => "X-B", "value" => "2"}
             ]

      FakeCDP.send_text(fake, ~s({"id":#{id},"result":{}}))
      assert :ok = Task.await(task)
    end

    test "fulfill_request accepts an iodata :body", %{page: page, fake: fake} do
      task = Task.async(fn -> Page.fulfill_request(page, "R1", body: ["<h1>", "hi", "</h1>"]) end)

      assert_receive {:fake_cdp_recv, ^fake,
                      %{"id" => id, "method" => "Fetch.fulfillRequest", "params" => params}},
                     2_000

      assert params["body"] == Base.encode64("<h1>hi</h1>")
      FakeCDP.send_text(fake, ~s({"id":#{id},"result":{}}))
      assert :ok = Task.await(task)
    end
  end

  describe "pdf/2" do
    test "reports an undecodable base64 payload, carrying the offending data", %{
      page: page,
      fake: fake
    } do
      task = Task.async(fn -> Page.pdf(page) end)

      assert_receive {:fake_cdp_recv, ^fake, %{"id" => id, "method" => "Page.printToPDF"}}, 2_000
      FakeCDP.send_text(fake, ~s({"id":#{id},"result":{"data":"!!!not base64!!!"}}))

      assert {:error, {:invalid_pdf_data, "!!!not base64!!!"}} = Task.await(task)
    end
  end

  describe "screenshot/2" do
    test "reports an undecodable base64 payload, carrying the offending data", %{
      page: page,
      fake: fake
    } do
      task = Task.async(fn -> Page.screenshot(page) end)

      assert_receive {:fake_cdp_recv, ^fake, %{"id" => id, "method" => "Page.captureScreenshot"}},
                     2_000

      FakeCDP.send_text(fake, ~s({"id":#{id},"result":{"data":"!!!not base64!!!"}}))

      assert {:error, {:invalid_screenshot_data, "!!!not base64!!!"}} = Task.await(task)
    end
  end

  # Poll until `pid` is registered as a `method` subscriber on `conn`, so events sent
  # afterward are guaranteed to be delivered to it (no send/subscribe race).
  defp wait_until_subscribed(conn, pid, method \\ "Page.lifecycleEvent", retries \\ 100) do
    cond do
      subscribed?(conn, pid, method) ->
        :ok

      retries == 0 ->
        flunk("subscriber not registered in time")

      true ->
        Process.sleep(10)
        wait_until_subscribed(conn, pid, method, retries - 1)
    end
  end

  defp subscribed?(conn, pid, method) do
    MapSet.member?(Map.get(:sys.get_state(conn).subscribers, method, MapSet.new()), pid)
  end
end
