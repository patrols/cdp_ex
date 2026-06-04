defmodule CDPEx.PageTest.StubBrowser do
  @moduledoc false
  # Minimal stand-in for CDPEx.Browser so the page-level interception tests exercise
  # the caller-side subscribe/enable path. Answers the reservation hops with a
  # configurable reply; the reservation *logic* (exclusion, monitor, auto-disable on
  # owner death) is covered directly in CDPEx.BrowserTest.
  use GenServer

  def start_link(reserve_reply \\ :ok, notify \\ nil),
    do: GenServer.start_link(__MODULE__, {reserve_reply, notify})

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call({:reserve_interception, page}, _from, {reply, notify} = state) do
    if notify, do: send(notify, {:stub_reserve, page})
    {:reply, reply, state}
  end

  def handle_call({:release_interception, page}, _from, {_reply, notify} = state) do
    if notify, do: send(notify, {:stub_release, page})
    {:reply, :ok, state}
  end
end

defmodule CDPEx.PageTest do
  use ExUnit.Case, async: true

  alias CDPEx.Connection
  alias CDPEx.FakeCDP
  alias CDPEx.Page
  alias CDPEx.PageTest.StubBrowser

  @network_methods ["Network.requestWillBeSent", "Network.responseReceived"]
  @idle_methods ["Network.requestWillBeSent", "Network.loadingFinished", "Network.loadingFailed"]

  setup do
    # The test process owns the linked connection (via start_link), so trap exits
    # and tolerate an already-dying conn in teardown — same as ConnectionTest.
    Process.flag(:trap_exit, true)

    {:ok, server} = FakeCDP.start()
    {:ok, conn} = Connection.start_link(server.url)
    assert_receive {:fake_cdp_connected, fake}, 2_000

    {:ok, browser} = StubBrowser.start_link(:ok, self())

    on_exit(fn ->
      try do
        if Process.alive?(conn), do: Connection.close(conn)
      catch
        :exit, _ -> :ok
      end
    end)

    %{
      page: %Page{browser: browser, conn: conn, target_id: "T", session_id: nil},
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

  describe "navigate/3 with response: true" do
    test "reports the main document's status + final URL, correlated by loaderId", %{
      page: page,
      conn: conn,
      fake: fake
    } do
      task = Task.async(fn -> Page.navigate(page, "http://example.test/", response: true) end)

      # response: true enables the Network domain first (responseReceived needs it).
      assert_receive {:fake_cdp_recv, ^fake, %{"id" => nid, "method" => "Network.enable"}}, 2_000
      FakeCDP.send_text(fake, ~s({"id":#{nid},"result":{}}))

      # Both the lifecycle and responseReceived subscriptions are in place before navigate.
      # response: true captures in an internal helper process, so match any subscriber pid.
      wait_until_any_subscribed(conn, "Network.responseReceived")
      wait_until_any_subscribed(conn, "Page.lifecycleEvent")

      assert_receive {:fake_cdp_recv, ^fake, %{"id" => navid, "method" => "Page.navigate"}}, 2_000
      FakeCDP.send_text(fake, ~s({"id":#{navid},"result":{"frameId":"F","loaderId":"L"}}))

      # Two Document responses share this navigation's loaderId — a redirect hop, then
      # the landing. The last one wins, so the post-redirect 200 is reported, not the 302.
      FakeCDP.send_text(
        fake,
        ~s({"method":"Network.responseReceived","params":{"type":"Document","loaderId":"L","frameId":"F","response":{"status":302,"url":"http://example.test/"}}})
      )

      FakeCDP.send_text(
        fake,
        ~s({"method":"Network.responseReceived","params":{"type":"Document","loaderId":"L","frameId":"F","response":{"status":200,"url":"http://example.test/landed"}}})
      )

      # The readiness milestone closes the capture window.
      FakeCDP.send_text(
        fake,
        ~s({"method":"Page.lifecycleEvent","params":{"name":"networkAlmostIdle"}})
      )

      assert {:ok, %Page{}, %{status: 200, url: "http://example.test/landed"}} = Task.await(task)
    end

    test "ignores a Document response from another navigation (loaderId mismatch)", %{
      page: page,
      conn: conn,
      fake: fake
    } do
      task =
        Task.async(fn ->
          Page.navigate(page, "http://example.test/", response: true, timeout: 1_000)
        end)

      assert_receive {:fake_cdp_recv, ^fake, %{"id" => nid, "method" => "Network.enable"}}, 2_000
      FakeCDP.send_text(fake, ~s({"id":#{nid},"result":{}}))

      wait_until_any_subscribed(conn, "Network.responseReceived")

      assert_receive {:fake_cdp_recv, ^fake, %{"id" => navid, "method" => "Page.navigate"}}, 2_000
      FakeCDP.send_text(fake, ~s({"id":#{navid},"result":{"frameId":"F","loaderId":"L"}}))

      # A Document response carrying a *different* loaderId must not be mistaken for
      # ours; with no matching response by the deadline, navigate reports the miss.
      FakeCDP.send_text(
        fake,
        ~s({"method":"Network.responseReceived","params":{"type":"Document","loaderId":"OTHER","frameId":"F","response":{"status":200,"url":"http://example.test/other"}}})
      )

      assert {:error, {:no_document_response, "http://example.test/"}} = Task.await(task)
    end

    test "the default navigate/3 still returns a bare {:ok, page} (no response capture)", %{
      page: page,
      conn: conn,
      fake: fake
    } do
      task = Task.async(fn -> Page.navigate(page, "http://example.test/") end)

      # No Network.enable on the default path — it only subscribes to lifecycle.
      wait_until_subscribed(conn, task.pid, "Page.lifecycleEvent")

      assert_receive {:fake_cdp_recv, ^fake, %{"id" => navid, "method" => "Page.navigate"}}, 2_000
      FakeCDP.send_text(fake, ~s({"id":#{navid},"result":{"frameId":"F","loaderId":"L"}}))

      FakeCDP.send_text(
        fake,
        ~s({"method":"Page.lifecycleEvent","params":{"name":"networkAlmostIdle"}})
      )

      assert {:ok, %Page{}} = Task.await(task)
    end

    test "wait_until: :none returns on the document response itself (no milestone wait)", %{
      page: page,
      conn: conn,
      fake: fake
    } do
      task =
        Task.async(fn ->
          Page.navigate(page, "http://example.test/", response: true, wait_until: :none)
        end)

      assert_receive {:fake_cdp_recv, ^fake, %{"id" => nid, "method" => "Network.enable"}}, 2_000
      FakeCDP.send_text(fake, ~s({"id":#{nid},"result":{}}))

      wait_until_any_subscribed(conn, "Network.responseReceived")

      assert_receive {:fake_cdp_recv, ^fake, %{"id" => navid, "method" => "Page.navigate"}}, 2_000
      FakeCDP.send_text(fake, ~s({"id":#{navid},"result":{"frameId":"F","loaderId":"L"}}))

      # With :none there is NO lifecycle milestone — the matching Document response is
      # itself the completion signal, so the call returns without a networkAlmostIdle.
      FakeCDP.send_text(
        fake,
        ~s({"method":"Network.responseReceived","params":{"type":"Document","loaderId":"L","frameId":"F","response":{"status":200,"url":"http://example.test/landed"}}})
      )

      assert {:ok, %Page{}, %{status: 200, url: "http://example.test/landed"}} = Task.await(task)
    end

    test "a connection death mid-capture surfaces as an error (never hangs)", %{
      page: page,
      conn: conn,
      fake: fake
    } do
      task = Task.async(fn -> Page.navigate(page, "http://example.test/", response: true) end)

      assert_receive {:fake_cdp_recv, ^fake, %{"id" => nid, "method" => "Network.enable"}}, 2_000
      FakeCDP.send_text(fake, ~s({"id":#{nid},"result":{}}))

      wait_until_any_subscribed(conn, "Network.responseReceived")

      assert_receive {:fake_cdp_recv, ^fake, %{"id" => navid, "method" => "Page.navigate"}}, 2_000
      FakeCDP.send_text(fake, ~s({"id":#{navid},"result":{"frameId":"F","loaderId":"L"}}))

      # The helper is now in await_capture (which monitors the conn). Drop the connection
      # before any document response: the wait must end with an error, not hang. Either
      # the await_capture {:DOWN} (-> {:ws_closed, _}) or the in-flight call (-> :noproc)
      # wins the race; both are clean errors.
      Connection.close(conn)

      assert {:error, reason} = Task.await(task)
      assert reason == :noproc or match?({:ws_closed, _}, reason)
    end

    test "respects :timeout as an overall ceiling — an unanswered Network.enable fails promptly (#49)",
         %{page: page, fake: fake} do
      # One deadline spans enable + subscribe + navigate + the capture wait. With
      # Network.enable never answered, the call surfaces the enable timeout from the shared
      # budget rather than hanging past it.
      task =
        Task.async(fn ->
          Page.navigate(page, "http://example.test/", response: true, timeout: 300)
        end)

      assert_receive {:fake_cdp_recv, ^fake, %{"method" => "Network.enable"}}, 2_000
      # Deliberately no reply.

      assert {:error, {:timeout, "Network.enable"}} = Task.await(task, 2_000)
    end

    test "leaves a same-process observe_network/2 subscription and buffered events intact (#42)",
         %{page: page, conn: conn, fake: fake} do
      test = self()

      # The caller observes the network AND navigates with response: true on the same
      # page. Before #42 the navigation tore the observer's subscription down and drained
      # its buffered events; with the isolated capture helper both survive.
      caller =
        spawn_link(fn ->
          :ok = Page.observe_network(page)
          send(test, :observing)

          result = Page.navigate(page, "http://example.test/", response: true)

          send(
            test,
            {:caller_done, result, subscribed?(conn, self(), "Network.responseReceived"),
             drain_cdp_events(conn, "Network.responseReceived", [])}
          )
        end)

      # observe_network/2: subscribe the caller, then answer its Network.enable.
      wait_until_subscribed(conn, caller, "Network.responseReceived")
      answer_network_enable(fake)
      assert_receive :observing, 2_000

      # navigate(response: true): re-enables Network (idempotent), then the helper
      # subscribes (responseReceived count climbs to 2: caller + helper) and navigates.
      answer_network_enable(fake)
      wait_until_subscriber_count(conn, "Network.responseReceived", 2)
      assert_receive {:fake_cdp_recv, ^fake, %{"id" => navid, "method" => "Page.navigate"}}, 2_000
      FakeCDP.send_text(fake, ~s({"id":#{navid},"result":{"frameId":"F","loaderId":"L"}}))

      # A sub-resource response (only the observer cares) and the main document response
      # (the helper captures it; the observer also gets its own copy). Both subscribers
      # receive their own copy — the helper's capture loop drains only the helper's mailbox.
      FakeCDP.send_text(
        fake,
        ~s({"method":"Network.responseReceived","params":{"requestId":"SUB","response":{"status":204,"url":"http://example.test/asset.js"}}})
      )

      FakeCDP.send_text(
        fake,
        ~s({"method":"Network.responseReceived","params":{"type":"Document","loaderId":"L","frameId":"F","response":{"status":200,"url":"http://example.test/landed"}}})
      )

      FakeCDP.send_text(
        fake,
        ~s({"method":"Page.lifecycleEvent","params":{"name":"networkAlmostIdle"}})
      )

      assert_receive {:caller_done, result, still_subscribed?, buffered}, 2_000

      assert {:ok, %Page{}, %{status: 200, url: "http://example.test/landed"}} = result
      assert still_subscribed?, "navigate(response: true) tore down the observer's subscription"

      statuses = for %{"response" => %{"status" => s}} <- buffered, do: s
      assert 204 in statuses, "observer lost its buffered sub-resource response"
      assert 200 in statuses, "observer lost its own copy of the document response"
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

      # The rollback issues a best-effort Fetch.disable (covers the timed-out-but-
      # enabled brick edge); answer it so the rollback completes promptly.
      assert_receive {:fake_cdp_recv, ^fake, %{"id" => did, "method" => "Fetch.disable"}}, 2_000
      FakeCDP.send_text(fake, ~s({"id":#{did},"result":{}}))

      assert_receive {:enable_result, {:error, {:cdp_error, "Fetch.enable", _}}}, 2_000
      refute subscribed?(conn, observer, "Fetch.requestPaused")

      # The reservation must be released on the rollback path, else the page stays
      # locked in the browser's intercepts map after a failed enable.
      assert_receive {:stub_release, _}, 2_000

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

  describe "wait_for_response/3" do
    test "resolves on the first response whose URL matches, returning its params", %{
      page: page,
      conn: conn,
      fake: fake
    } do
      task = Task.async(fn -> Page.wait_for_response(page, "/api/data", timeout: 2_000) end)

      assert_receive {:fake_cdp_recv, ^fake, %{"id" => nid, "method" => "Network.enable"}}, 2_000
      FakeCDP.send_text(fake, ~s({"id":#{nid},"result":{}}))

      # await_event registers a connection-side waiter (no subscription) — wait for it,
      # then feed a non-matching response before the match.
      wait_until_waiting(conn)

      FakeCDP.send_text(
        fake,
        ~s({"method":"Network.responseReceived","params":{"requestId":"R0","response":{"url":"http://x/other","status":200}}})
      )

      FakeCDP.send_text(
        fake,
        ~s({"method":"Network.responseReceived","params":{"requestId":"R1","response":{"url":"http://x/api/data","status":201}}})
      )

      assert {:ok,
              %{"requestId" => "R1", "response" => %{"status" => 201, "url" => "http://x/api/data"}}} =
               Task.await(task)
    end

    test "accepts a function matcher over the response URL", %{page: page, conn: conn, fake: fake} do
      task =
        Task.async(fn ->
          Page.wait_for_response(page, &String.ends_with?(&1, ".json"), timeout: 2_000)
        end)

      assert_receive {:fake_cdp_recv, ^fake, %{"id" => nid, "method" => "Network.enable"}}, 2_000
      FakeCDP.send_text(fake, ~s({"id":#{nid},"result":{}}))
      wait_until_waiting(conn)

      FakeCDP.send_text(
        fake,
        ~s({"method":"Network.responseReceived","params":{"requestId":"R1","response":{"url":"http://x/feed.json","status":200}}})
      )

      assert {:ok, %{"requestId" => "R1"}} = Task.await(task)
    end

    test "maps the await timeout to a bare {:error, :timeout}", %{page: page, fake: fake} do
      task = Task.async(fn -> Page.wait_for_response(page, ~r/never-matches/, timeout: 150) end)

      assert_receive {:fake_cdp_recv, ^fake, %{"id" => nid, "method" => "Network.enable"}}, 2_000
      FakeCDP.send_text(fake, ~s({"id":#{nid},"result":{}}))

      assert {:error, :timeout} = Task.await(task)
    end

    test "accepts a Regex matcher over the response URL", %{page: page, conn: conn, fake: fake} do
      task = Task.async(fn -> Page.wait_for_response(page, ~r{/api/v\d+/data}, timeout: 2_000) end)

      assert_receive {:fake_cdp_recv, ^fake, %{"id" => nid, "method" => "Network.enable"}}, 2_000
      FakeCDP.send_text(fake, ~s({"id":#{nid},"result":{}}))
      wait_until_waiting(conn)

      FakeCDP.send_text(
        fake,
        ~s({"method":"Network.responseReceived","params":{"requestId":"R1","response":{"url":"http://x/api/v2/data","status":200}}})
      )

      assert {:ok, %{"requestId" => "R1"}} = Task.await(task)
    end

    test "errors if the connection drops while awaiting", %{page: page, conn: conn, fake: fake} do
      task = Task.async(fn -> Page.wait_for_response(page, "/never", timeout: 3_000) end)

      assert_receive {:fake_cdp_recv, ^fake, %{"id" => nid, "method" => "Network.enable"}}, 2_000
      FakeCDP.send_text(fake, ~s({"id":#{nid},"result":{}}))
      wait_until_waiting(conn)

      Connection.close(conn)

      assert {:error, reason} = Task.await(task, 2_000)
      assert reason == :noproc or match?({:ws_closed, _}, reason)
    end
  end

  describe "wait_for_network_idle/2" do
    test "resolves when nothing is in flight from the call onward", %{page: page, fake: fake} do
      task = Task.async(fn -> Page.wait_for_network_idle(page, idle_time: 100, timeout: 2_000) end)
      enable_network_idle(fake)
      assert :ok = Task.await(task, 2_000)
    end

    test "resolves once in-flight requests complete and the network goes quiet", %{
      page: page,
      conn: conn,
      fake: fake
    } do
      task = Task.async(fn -> Page.wait_for_network_idle(page, idle_time: 150, timeout: 3_000) end)
      enable_network_idle(fake, conn)

      # Two requests start (in-flight 2 > 0 → busy, idle timer cancelled), then both end.
      send_network_event(fake, "Network.requestWillBeSent", "R1")
      send_network_event(fake, "Network.requestWillBeSent", "R2")
      send_network_event(fake, "Network.loadingFinished", "R1")
      send_network_event(fake, "Network.loadingFailed", "R2")

      # Back to 0 in flight → the idle timer rearms and fires after idle_time.
      assert :ok = Task.await(task, 3_000)
    end

    test "clamps in-flight at zero on extra completions", %{page: page, conn: conn, fake: fake} do
      task = Task.async(fn -> Page.wait_for_network_idle(page, idle_time: 100, timeout: 2_000) end)
      enable_network_idle(fake, conn)

      # One request, three completions: the counter must clamp at 0 (never negative)
      # and still resolve.
      send_network_event(fake, "Network.requestWillBeSent", "R1")
      send_network_event(fake, "Network.loadingFinished", "R1")
      send_network_event(fake, "Network.loadingFinished", "R1")
      send_network_event(fake, "Network.loadingFailed", "R1")

      assert :ok = Task.await(task, 2_000)
    end

    test "times out while a request stays in flight", %{page: page, conn: conn, fake: fake} do
      task = Task.async(fn -> Page.wait_for_network_idle(page, idle_time: 200, timeout: 500) end)
      enable_network_idle(fake, conn)

      # A request that never completes keeps in-flight at 1 (> 0), so it never idles.
      send_network_event(fake, "Network.requestWillBeSent", "R1")

      assert {:error, :timeout} = Task.await(task, 2_000)
    end

    test "errors if the connection drops while waiting", %{page: page, conn: conn, fake: fake} do
      task =
        Task.async(fn -> Page.wait_for_network_idle(page, idle_time: 1_000, timeout: 3_000) end)

      enable_network_idle(fake, conn)

      # Keep it busy so the idle timer can't fire, then drop the connection.
      send_network_event(fake, "Network.requestWillBeSent", "R1")
      Connection.close(conn)

      assert {:error, reason} = Task.await(task, 2_000)
      assert reason == :noproc or match?({:ws_closed, _}, reason)
    end

    test "does not count redirect hops (requestWillBeSent carrying redirectResponse)", %{
      page: page,
      conn: conn,
      fake: fake
    } do
      task = Task.async(fn -> Page.wait_for_network_idle(page, idle_time: 150, timeout: 3_000) end)
      enable_network_idle(fake, conn)

      # A redirecting request: the initial requestWillBeSent (+1), then a redirect hop
      # (requestWillBeSent carrying redirectResponse — must NOT add another +1), then the
      # single terminal loadingFinished (−1). Net 0 → idle. Pre-fix this stuck at +1 →
      # {:error, :timeout}.
      send_network_event(fake, "Network.requestWillBeSent", "R1")

      FakeCDP.send_text(
        fake,
        ~s({"method":"Network.requestWillBeSent","params":{"requestId":"R1","redirectResponse":{"status":302}}})
      )

      send_network_event(fake, "Network.loadingFinished", "R1")

      assert :ok = Task.await(task, 3_000)
    end

    test "a completion for a request started before the call doesn't cause a false idle", %{
      page: page,
      conn: conn,
      fake: fake
    } do
      task = Task.async(fn -> Page.wait_for_network_idle(page, idle_time: 150, timeout: 5_000) end)
      enable_network_idle(fake, conn)

      # A NEW request (seen after the call) is in flight.
      send_network_event(fake, "Network.requestWillBeSent", "NEW")

      # A request that started BEFORE the call completes during the wait. Its id was never
      # tracked, so its terminal event must NOT clear NEW's slot — the wait stays busy.
      send_network_event(fake, "Network.loadingFinished", "PRECALL")
      refute Task.yield(task, 300), "false idle: a pre-call completion cleared a live request"

      # NEW completes → genuinely idle.
      send_network_event(fake, "Network.loadingFinished", "NEW")
      assert :ok = Task.await(task, 3_000)
    end

    test "max_inflight: 2 stays idle at the threshold, busies above it", %{
      page: page,
      conn: conn,
      fake: fake
    } do
      task =
        Task.async(fn ->
          Page.wait_for_network_idle(page, max_inflight: 2, idle_time: 150, timeout: 5_000)
        end)

      enable_network_idle(fake, conn)

      # 3 in flight (> max_inflight 2) → busy: must not resolve even past idle_time.
      send_network_event(fake, "Network.requestWillBeSent", "R1")
      send_network_event(fake, "Network.requestWillBeSent", "R2")
      send_network_event(fake, "Network.requestWillBeSent", "R3")
      refute Task.yield(task, 300), "resolved while 3 requests were in flight (max_inflight: 2)"

      # Drop back to 2 (≤ threshold) → the idle timer rearms and resolves.
      send_network_event(fake, "Network.loadingFinished", "R3")
      assert :ok = Task.await(task, 3_000)
    end

    test "a new request resets the idle timer (armed → cancelled → rearmed)", %{
      page: page,
      conn: conn,
      fake: fake
    } do
      task = Task.async(fn -> Page.wait_for_network_idle(page, idle_time: 200, timeout: 5_000) end)
      enable_network_idle(fake, conn)

      # Request then complete → the idle timer arms (in-flight 0).
      send_network_event(fake, "Network.requestWillBeSent", "R1")
      send_network_event(fake, "Network.loadingFinished", "R1")
      Process.sleep(60)

      # A new request before idle_time elapses must cancel the armed timer (busy again).
      send_network_event(fake, "Network.requestWillBeSent", "R2")
      refute Task.yield(task, 300), "resolved despite a new request before idle_time"

      # Complete it → rearm → resolve.
      send_network_event(fake, "Network.loadingFinished", "R2")
      assert :ok = Task.await(task, 3_000)
    end

    test "an enable failure leaves no lingering idle subscriptions", %{
      page: page,
      conn: conn,
      fake: fake
    } do
      task = Task.async(fn -> Page.wait_for_network_idle(page, idle_time: 100, timeout: 1_000) end)

      # The helper subscribes to the idle methods before enabling Network.
      for m <- @idle_methods, do: wait_until_any_subscribed(conn, m)

      assert_receive {:fake_cdp_recv, ^fake, %{"id" => nid, "method" => "Network.enable"}}, 2_000
      FakeCDP.send_text(fake, ~s({"id":#{nid},"error":{"code":-32000,"message":"boom"}}))

      assert {:error, {:cdp_error, "Network.enable", _}} = Task.await(task)

      # The helper exited on the error → Connection pruned its idle-method subscriptions
      # on the resulting :DOWN, so nothing is left subscribed on the connection.
      for m <- @idle_methods, do: wait_until_no_subscribers(conn, m)
    end

    test "leaves a same-process observe_network/2 subscription and buffered events intact (#48)",
         %{page: page, conn: conn, fake: fake} do
      test = self()

      # The caller observes the network AND waits for idle on the same page. Before #48 the
      # idle wait tore down the observer's overlapping requestWillBeSent subscription and
      # drained its buffered events; with the isolated helper both survive.
      caller =
        spawn_link(fn ->
          :ok = Page.observe_network(page)
          send(test, :observing)

          result = Page.wait_for_network_idle(page, idle_time: 100, timeout: 2_000)

          send(
            test,
            {:caller_done, result, subscribed?(conn, self(), "Network.requestWillBeSent"),
             drain_cdp_events(conn, "Network.requestWillBeSent", [])}
          )
        end)

      # observe_network/2 subscribes the caller (requestWillBeSent + responseReceived), then
      # answer its Network.enable.
      wait_until_subscribed(conn, caller, "Network.requestWillBeSent")
      answer_network_enable(fake)
      assert_receive :observing, 2_000

      # wait_for_network_idle re-enables Network (idempotent); the helper subscribes to the
      # idle methods (gated on loadingFinished, which only the helper observes) and enters
      # its loop. enable_network_idle waits for those subs + answers the second enable.
      enable_network_idle(fake, conn)

      # One request that starts and finishes: the helper counts it and, after idle_time with
      # nothing in flight, resolves :ok. The observer gets its own copy of the
      # requestWillBeSent (the helper's loop drains only the helper's mailbox).
      send_network_event(fake, "Network.requestWillBeSent", "R1")
      send_network_event(fake, "Network.loadingFinished", "R1")

      assert_receive {:caller_done, result, still_subscribed?, buffered}, 3_000

      assert result == :ok
      assert still_subscribed?, "wait_for_network_idle tore down the observer's subscription"

      ids = for %{"requestId" => id} <- buffered, do: id
      assert "R1" in ids, "observer lost its buffered requestWillBeSent event"
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

  # Like wait_until_subscribed/3 but matches *any* subscriber — used where the subscriber
  # is an internal helper process whose pid the test can't name (e.g. the response-capture
  # helper in navigate(response: true), #42).
  defp wait_until_any_subscribed(conn, method, retries \\ 100),
    do: wait_until_subscriber_count(conn, method, 1, retries)

  # Poll until `method` has at least `count` distinct subscriber pids.
  defp wait_until_subscriber_count(conn, method, count, retries \\ 100) do
    cond do
      MapSet.size(Map.get(:sys.get_state(conn).subscribers, method, MapSet.new())) >= count ->
        :ok

      retries == 0 ->
        flunk("fewer than #{count} subscribers for #{method} registered in time")

      true ->
        Process.sleep(10)
        wait_until_subscriber_count(conn, method, count, retries - 1)
    end
  end

  # Poll until `method` has zero subscribers — e.g. after an internal helper exits and
  # Connection prunes it on the resulting :DOWN.
  defp wait_until_no_subscribers(conn, method, retries \\ 100) do
    cond do
      MapSet.size(Map.get(:sys.get_state(conn).subscribers, method, MapSet.new())) == 0 ->
        :ok

      retries == 0 ->
        flunk("subscribers for #{method} not pruned in time")

      true ->
        Process.sleep(10)
        wait_until_no_subscribers(conn, method, retries - 1)
    end
  end

  # Collect every buffered `method` cdp_event currently in this process's mailbox (the
  # observer's copies), returning their params maps. `after 0` is safe here: the copies are
  # enqueued (local sends are synchronous) before the helper sends the {:caller_done, ...}
  # that unblocks the caller, so they are already in the mailbox by the time this runs — no
  # flake window.
  defp drain_cdp_events(conn, method, acc) do
    receive do
      {:cdp_event, ^conn, ^method, params, _sid} ->
        drain_cdp_events(conn, method, [params | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  # Answer one Network.enable command with an empty result.
  defp answer_network_enable(fake) do
    assert_receive {:fake_cdp_recv, ^fake, %{"id" => nid, "method" => "Network.enable"}}, 2_000
    FakeCDP.send_text(fake, ~s({"id":#{nid},"result":{}}))
  end

  # Poll until at least one await_event waiter is registered on `conn` (waiters are not
  # subscriptions, so they can't be observed via `subscribed?/3`).
  defp wait_until_waiting(conn, retries \\ 100) do
    cond do
      :sys.get_state(conn).waiters != [] -> :ok
      retries == 0 -> flunk("await_event waiter not registered in time")
      true -> Process.sleep(10) && wait_until_waiting(conn, retries - 1)
    end
  end

  # Answer the Network.enable that wait_for_network_idle/2 issues. When `conn` is given,
  # first wait until the three idle subscriptions are registered (subscribe runs before
  # enable, from the internal helper process whose pid the test can't name), so events sent
  # afterward are delivered rather than dropped by the drain.
  defp enable_network_idle(fake, conn \\ nil) do
    if conn, do: for(m <- @idle_methods, do: wait_until_any_subscribed(conn, m))
    assert_receive {:fake_cdp_recv, ^fake, %{"id" => nid, "method" => "Network.enable"}}, 2_000
    FakeCDP.send_text(fake, ~s({"id":#{nid},"result":{}}))
    # Let the helper drain stale events and enter the receive loop before the caller sends
    # events, so they land in the loop rather than being swallowed by the pre-loop drain.
    if conn, do: Process.sleep(50)
  end

  defp send_network_event(fake, method, request_id) do
    FakeCDP.send_text(fake, ~s({"method":"#{method}","params":{"requestId":"#{request_id}"}}))
  end
end
