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

  describe "keymap/1" do
    test "every supported key maps to its standard windows virtual key code" do
      # Guards against a transposed keyCode (e.g. ArrowUp/ArrowDown), which Chrome
      # would silently honor as the wrong key with no CDP error.
      expected = %{
        "Enter" => 13,
        "Tab" => 9,
        "Escape" => 27,
        "Backspace" => 8,
        "Delete" => 46,
        "ArrowUp" => 38,
        "ArrowDown" => 40,
        "ArrowLeft" => 37,
        "ArrowRight" => 39,
        "Home" => 36,
        "End" => 35
      }

      for {key, vk} <- expected do
        assert {:ok, %{"key" => ^key, "code" => ^key, "windowsVirtualKeyCode" => ^vk}} =
                 Page.keymap(key)
      end
    end

    test "Enter carries text so its default action fires" do
      assert {:ok, %{"text" => "\r"}} = Page.keymap("Enter")
    end

    test "unknown key is an error" do
      assert {:error, {:unknown_key, "F13"}} = Page.keymap("F13")
    end
  end

  describe "set_user_agent/3" do
    test "passes userAgentMetadata + acceptLanguage through to setUserAgentOverride", %{
      fake: fake,
      page: page
    } do
      meta = %{
        "platform" => "macOS",
        "mobile" => false,
        "brands" => [%{"brand" => "Chromium", "version" => "120"}]
      }

      task =
        Task.async(fn ->
          Page.set_user_agent(page, "UA/1.0", user_agent_metadata: meta, accept_language: "en-US")
        end)

      assert_receive {:fake_cdp_recv, ^fake,
                      %{
                        "id" => id,
                        "method" => "Emulation.setUserAgentOverride",
                        "params" => params
                      }},
                     2_000

      assert params["userAgent"] == "UA/1.0"
      assert params["userAgentMetadata"] == meta
      assert params["acceptLanguage"] == "en-US"

      FakeCDP.send_text(fake, ~s({"id":#{id},"result":{}}))
      assert :ok = Task.await(task)
    end

    test "omits userAgentMetadata/acceptLanguage when not given", %{fake: fake, page: page} do
      task = Task.async(fn -> Page.set_user_agent(page, "UA/1.0") end)

      assert_receive {:fake_cdp_recv, ^fake,
                      %{
                        "id" => id,
                        "method" => "Emulation.setUserAgentOverride",
                        "params" => params
                      }},
                     2_000

      assert params == %{"userAgent" => "UA/1.0"}

      FakeCDP.send_text(fake, ~s({"id":#{id},"result":{}}))
      assert :ok = Task.await(task)
    end
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

  describe "wait_for_selector/3 encoding" do
    # These tests pin the wire-level Runtime.evaluate expression so the selector's
    # quote characters can't be re-introduced into the JS source by a future refactor
    # that drops the Jason.encode! boundary. They run without Chrome so they always
    # run in CI's default lane, unlike the integration coverage.
    test "encodes a single-quoted attribute selector as a double-quoted JS string", %{
      page: page,
      fake: fake
    } do
      assert_wait_for_selector_expression(
        page,
        fake,
        "[id^='ticket-card-']",
        ~s{!!(document.querySelector("[id^='ticket-card-']") !== null)}
      )
    end

    test "encodes a double-quoted attribute selector by escaping the embedded quotes", %{
      page: page,
      fake: fake
    } do
      assert_wait_for_selector_expression(
        page,
        fake,
        ~S([id^="ticket-card-"]),
        ~s{!!(document.querySelector("[id^=\\"ticket-card-\\"]") !== null)}
      )
    end

    test "encodes an attribute value that itself contains a quote character", %{
      page: page,
      fake: fake
    } do
      # The deepest case: a double-quoted attribute selector whose value carries a
      # literal single quote (`a'b`). JSON escapes only the wrapping double quotes,
      # leaving the inner single quote untouched — pinned here Chrome-free.
      assert_wait_for_selector_expression(
        page,
        fake,
        ~S([data-label="a'b"]),
        ~s{!!(document.querySelector("[data-label=\\"a'b\\"]") !== null)}
      )
    end

    test "surfaces an exceptionDetails response as :fatal instead of polling on", %{
      page: page,
      fake: fake
    } do
      # A JS exception (e.g. an invalid CSS selector that querySelector throws on) must
      # terminate the wait with the exception rather than collapse to "no match" and
      # poll forever. probe_truthy classifies *cdp_error* responses as transient
      # (context torn down mid-navigation) but exceptionDetails as fatal — a regression
      # that merged the two would silently re-introduce the "30s timeout for any bad
      # selector" bug.
      task =
        Task.async(fn ->
          Page.wait_for_selector(page, ":::", timeout: 2_000, interval: 10)
        end)

      assert_receive {:fake_cdp_recv, ^fake, %{"id" => id, "method" => "Runtime.evaluate"}}, 2_000

      exception_details = %{
        "text" => "Uncaught",
        "exception" => %{"className" => "DOMException", "description" => "SyntaxError"}
      }

      # Wire-faithful Runtime.evaluate reply: real Chrome returns `exceptionDetails`
      # as a sibling of the `result` RemoteObject, not nested under it.
      FakeCDP.send_text(
        fake,
        Jason.encode!(%{
          "id" => id,
          "result" => %{
            "result" => %{"type" => "object", "subtype" => "error", "className" => "DOMException"},
            "exceptionDetails" => exception_details
          }
        })
      )

      assert {:error, {:evaluate_exception, ^exception_details}} = Task.await(task, 2_000)
    end

    test "keeps polling on a transient cdp_error, then resolves when the element appears", %{
      page: page,
      fake: fake
    } do
      # The mirror of the exceptionDetails case: a CDP-level error (e.g. the
      # execution context is being rebuilt mid-navigation) is transient, so the
      # wait must keep polling rather than surface it. Answer the first
      # Runtime.evaluate with a CDP error, prove a SECOND evaluate is issued
      # (it polled on), then resolve truthy. A regression that merged the
      # transient and fatal arms of probe_truthy/2 would terminate on the first
      # error and never issue the second poll — failing this test.
      task =
        Task.async(fn ->
          Page.wait_for_selector(page, "#late", timeout: 2_000, interval: 10)
        end)

      assert_receive {:fake_cdp_recv, ^fake, %{"id" => id1, "method" => "Runtime.evaluate"}}, 2_000

      FakeCDP.send_text(
        fake,
        ~s({"id":#{id1},"error":{"code":-32000,"message":"Cannot find context with specified id"}})
      )

      assert_receive {:fake_cdp_recv, ^fake, %{"id" => id2, "method" => "Runtime.evaluate"}}, 2_000

      FakeCDP.send_text(
        fake,
        ~s({"id":#{id2},"result":{"result":{"type":"boolean","value":true}}})
      )

      assert :ok = Task.await(task, 2_000)
    end

    test "stops on a closed session but polls through a missing context on one (#121)", %{
      page: page,
      fake: fake
    } do
      page = %{page | session_id: "S"}

      task =
        Task.async(fn ->
          Page.wait_for_selector(page, "#late", timeout: 5_000, interval: 10)
        end)

      assert_receive {:fake_cdp_recv, ^fake, %{"id" => id1, "method" => "Runtime.evaluate"}}, 2_000

      FakeCDP.send_text(
        fake,
        ~s({"id":#{id1},"sessionId":"S","error":{"code":-32000,"message":"Cannot find context with specified id"}})
      )

      assert_receive {:fake_cdp_recv, ^fake, %{"id" => id2, "method" => "Runtime.evaluate"}}, 2_000

      FakeCDP.send_text(
        fake,
        ~s({"id":#{id2},"error":{"code":-32001,"message":"Session with given id not found."}})
      )

      assert {:error, {:session_closed, "S"}} = Task.await(task, 1_000)
      refute_receive {:fake_cdp_recv, ^fake, %{"method" => "Runtime.evaluate"}}, 100
    end
  end

  describe "click/3 :wait" do
    test "retries while the selector is missing, then clicks", %{page: page, fake: fake} do
      task = Task.async(fn -> Page.click(page, "#late", wait: 2_000, trusted: false) end)

      reply_evaluate(fake, false)
      reply_evaluate(fake, false)
      reply_evaluate(fake, true)

      assert :ok = Task.await(task, 2_000)
    end

    test "retries a trusted click while the element has no box, then dispatches", %{
      page: page,
      fake: fake
    } do
      task = Task.async(fn -> Page.click(page, "#late", wait: 2_000) end)

      reply_evaluate(fake, %{"found" => true, "clickable" => false})
      reply_evaluate(fake, %{"found" => true, "clickable" => true, "x" => 10, "y" => 20})

      for type <- ["mousePressed", "mouseReleased"] do
        assert_receive {:fake_cdp_recv, ^fake,
                        %{
                          "id" => id,
                          "method" => "Input.dispatchMouseEvent",
                          "params" => %{"type" => ^type, "x" => 10, "y" => 20}
                        }},
                       2_000

        FakeCDP.send_text(fake, ~s({"id":#{id},"result":{}}))
      end

      assert :ok = Task.await(task, 2_000)
    end

    test "returns the last retryable error once the budget is spent", %{page: page, fake: fake} do
      task = Task.async(fn -> Page.click(page, "#hidden", wait: 300) end)

      {result, attempts} =
        answer_until_done(task, fake, %{"found" => true, "clickable" => false})

      assert result == {:error, {:not_clickable, "#hidden"}}
      assert attempts > 1
    end

    test "an evaluate exception returns at once without spending the budget", %{
      page: page,
      fake: fake
    } do
      task = Task.async(fn -> Page.click(page, ":::", wait: 10_000) end)

      assert_receive {:fake_cdp_recv, ^fake, %{"id" => id, "method" => "Runtime.evaluate"}}, 2_000

      details = %{"text" => "Uncaught", "exception" => %{"description" => "SyntaxError"}}

      FakeCDP.send_text(
        fake,
        Jason.encode!(%{
          "id" => id,
          "result" => %{"result" => %{"type" => "object"}, "exceptionDetails" => details}
        })
      )

      assert {:error, {:evaluate_exception, ^details}} = Task.await(task, 1_000)
      refute_received {:fake_cdp_recv, ^fake, %{"method" => "Runtime.evaluate"}}
    end

    test "retries a missing-execution-context error from the locate step, then clicks", %{
      page: page,
      fake: fake
    } do
      task = Task.async(fn -> Page.click(page, "#btn", wait: 2_000) end)

      assert_receive {:fake_cdp_recv, ^fake, %{"id" => id, "method" => "Runtime.evaluate"}}, 2_000

      FakeCDP.send_text(
        fake,
        ~s({"id":#{id},"error":{"code":-32000,"message":"Cannot find context with specified id"}})
      )

      reply_evaluate(fake, %{"found" => true, "clickable" => true, "x" => 1, "y" => 2})

      for type <- ["mousePressed", "mouseReleased"] do
        assert_receive {:fake_cdp_recv, ^fake,
                        %{
                          "id" => mid,
                          "method" => "Input.dispatchMouseEvent",
                          "params" => %{"type" => ^type}
                        }},
                       2_000

        FakeCDP.send_text(fake, ~s({"id":#{mid},"result":{}}))
      end

      assert :ok = Task.await(task, 2_000)
    end

    test "trusted: retries a call torn down by navigation (it only located)", %{
      page: page,
      fake: fake
    } do
      task = Task.async(fn -> Page.click(page, "#btn", wait: 2_000) end)

      send_cdp_error(fake, "Inspected target navigated or closed")
      send_cdp_error(fake, "Execution context was destroyed.")
      reply_evaluate(fake, %{"found" => true, "clickable" => true, "x" => 1, "y" => 2})

      for type <- ["mousePressed", "mouseReleased"] do
        assert_receive {:fake_cdp_recv, ^fake, %{"id" => mid, "params" => %{"type" => ^type}}},
                       2_000

        FakeCDP.send_text(fake, ~s({"id":#{mid},"result":{}}))
      end

      assert :ok = Task.await(task, 2_000)
    end

    test "synthetic: retries a context that was never found (the script didn't run)", %{
      page: page,
      fake: fake
    } do
      task = Task.async(fn -> Page.click(page, "#btn", wait: 2_000, trusted: false) end)

      send_cdp_error(fake, "Cannot find default execution context")
      reply_evaluate(fake, true)

      assert :ok = Task.await(task, 2_000)
    end

    test "synthetic: never retries a context torn down mid-call (the click may have navigated)",
         %{page: page, fake: fake} do
      for message <- ["Inspected target navigated or closed", "Execution context was destroyed."] do
        task = Task.async(fn -> Page.click(page, "#btn", wait: 10_000, trusted: false) end)

        send_cdp_error(fake, message)

        assert {:error, {:cdp_error, "Runtime.evaluate", %{"message" => ^message}}} =
                 Task.await(task, 1_000)

        refute_receive {:fake_cdp_recv, ^fake, %{"method" => "Runtime.evaluate"}}, 200
      end
    end

    test "a CDP error other than a missing context from the locate step returns at once", %{
      page: page,
      fake: fake
    } do
      task = Task.async(fn -> Page.click(page, "#btn", wait: 10_000) end)

      assert_receive {:fake_cdp_recv, ^fake, %{"id" => id, "method" => "Runtime.evaluate"}}, 2_000

      FakeCDP.send_text(
        fake,
        ~s({"id":#{id},"error":{"code":-32000,"message":"Object reference chain is too long"}})
      )

      assert {:error, {:cdp_error, "Runtime.evaluate", %{"code" => -32_000}}} =
               Task.await(task, 1_000)

      refute_receive {:fake_cdp_recv, ^fake, %{"method" => "Runtime.evaluate"}}, 200
    end

    test "a detached session from the locate step returns at once", %{page: page, fake: fake} do
      page = %{page | session_id: "S"}
      task = Task.async(fn -> Page.click(page, "#btn", wait: 10_000) end)

      assert_receive {:fake_cdp_recv, ^fake, %{"id" => id, "method" => "Runtime.evaluate"}}, 2_000

      FakeCDP.send_text(
        fake,
        ~s({"id":#{id},"error":{"code":-32001,"message":"Session with given id not found."}})
      )

      assert {:error, {:session_closed, "S"}} = Task.await(task, 1_000)
      refute_receive {:fake_cdp_recv, ^fake, %{"method" => "Runtime.evaluate"}}, 200
    end

    test "never retries a CDP error from the mouse dispatch", %{page: page, fake: fake} do
      task = Task.async(fn -> Page.click(page, "#btn", wait: 10_000) end)

      reply_evaluate(fake, %{"found" => true, "clickable" => true, "x" => 1, "y" => 2})

      assert_receive {:fake_cdp_recv, ^fake,
                      %{"id" => press_id, "params" => %{"type" => "mousePressed"}}},
                     2_000

      FakeCDP.send_text(fake, ~s({"id":#{press_id},"result":{}}))

      assert_receive {:fake_cdp_recv, ^fake,
                      %{"id" => rid, "params" => %{"type" => "mouseReleased"}}},
                     2_000

      FakeCDP.send_text(fake, ~s({"id":#{rid},"error":{"code":-32000,"message":"boom"}}))

      assert {:error, {:cdp_error, "Input.dispatchMouseEvent", _}} = Task.await(task, 1_000)
      refute_receive {:fake_cdp_recv, ^fake, %{"method" => "Runtime.evaluate"}}, 200
    end

    test "wait: 0 (the default) is a single attempt", %{page: page, fake: fake} do
      task = Task.async(fn -> Page.click(page, "#nope", trusted: false) end)

      reply_evaluate(fake, false)

      assert {:error, {:selector_not_found, "#nope"}} = Task.await(task, 1_000)
      refute_receive {:fake_cdp_recv, ^fake, %{"method" => "Runtime.evaluate"}}, 200
    end

    test "raises on an invalid :wait", %{page: page} do
      assert_raise ArgumentError, ~r/invalid :wait -1/, fn ->
        Page.click(page, "#btn", wait: -1)
      end
    end
  end

  describe "click_text/3" do
    test "JSON-encodes the text and selector into the locator", %{page: page, fake: fake} do
      task =
        Task.async(fn ->
          Page.click_text(page, ~S(Say "hi" & it's), selector: ~S(button[data-x="y"]))
        end)

      assert_receive {:fake_cdp_recv, ^fake,
                      %{
                        "id" => id,
                        "method" => "Runtime.evaluate",
                        "params" => %{"expression" => expression}
                      }},
                     2_000

      assert expression =~ ~S{var target = norm("Say \"hi\" & it's");}
      assert expression =~ ~S{var selector = "button[data-x=\"y\"]";}

      FakeCDP.send_text(fake, evaluate_reply(id, %{"found" => false}))
      assert {:error, {:text_not_found, ~S(Say "hi" & it's)}} = Task.await(task, 2_000)
    end

    test "a missing :selector encodes as null", %{page: page, fake: fake} do
      task = Task.async(fn -> Page.click_text(page, "Go", trusted: false) end)

      assert_receive {:fake_cdp_recv, ^fake,
                      %{"id" => id, "params" => %{"expression" => expression}}},
                     2_000

      assert expression =~ "var selector = null;"
      FakeCDP.send_text(fake, evaluate_reply(id, false))
      assert {:error, {:text_not_found, "Go"}} = Task.await(task, 2_000)
    end

    test ":wait retries while the text is missing", %{page: page, fake: fake} do
      task = Task.async(fn -> Page.click_text(page, "Load more", wait: 2_000, trusted: false) end)

      reply_evaluate(fake, false)
      reply_evaluate(fake, true)

      assert :ok = Task.await(task, 2_000)
    end

    test "raises on empty or whitespace-only text without touching the page", %{
      page: page,
      fake: fake
    } do
      for text <- ["", "   ", " \t\r\n "] do
        assert_raise ArgumentError, ~r/invalid click_text\/3 text/, fn ->
          Page.click_text(page, text)
        end
      end

      refute_receive {:fake_cdp_recv, ^fake, _}, 100
    end

    test "raises on a non-string :selector without touching the page", %{page: page, fake: fake} do
      for selector <- [:button, 1] do
        assert_raise ArgumentError, ~r/invalid :selector/, fn ->
          Page.click_text(page, "Go", selector: selector)
        end
      end

      refute_receive {:fake_cdp_recv, ^fake, _}, 100
    end

    test "reports :not_clickable with the text", %{page: page, fake: fake} do
      task = Task.async(fn -> Page.click_text(page, "Hidden") end)

      reply_evaluate(fake, %{"found" => true, "clickable" => false})

      assert {:error, {:not_clickable, "Hidden"}} = Task.await(task, 2_000)
    end
  end

  describe "scroll/3" do
    test "scrolls instantly and returns :ok", %{page: page, fake: fake} do
      for {target, fragment} <- [
            {:top, "left: window.scrollX, top: 0,"},
            {:bottom, "document.documentElement.scrollHeight"},
            {{0, 250.5}, "left: 0, top: 250.5,"}
          ] do
        task = Task.async(fn -> Page.scroll(page, target) end)

        assert_receive {:fake_cdp_recv, ^fake,
                        %{"id" => id, "params" => %{"expression" => expression}}},
                       2_000

        assert expression =~ fragment
        assert expression =~ ~s(behavior: "instant")
        FakeCDP.send_text(fake, evaluate_reply(id, true))
        assert :ok = Task.await(task, 2_000)
      end
    end
  end

  describe "navigate/3 readiness wait" do
    test "ignores a stale milestone from a previous loader", %{page: page, conn: conn, fake: fake} do
      # Same hazard as the response: true capture, one notch quieter: a late
      # about:blank networkAlmostIdle (old loaderId) would end the readiness wait
      # before the real document loads, so the caller reads a half-built page.
      task = Task.async(fn -> Page.navigate(page, "http://example.test/") end)
      wait_until_subscribed(conn, task.pid)

      assert_receive {:fake_cdp_recv, ^fake, %{"id" => navid, "method" => "Page.navigate"}}, 2_000
      FakeCDP.send_text(fake, ~s({"id":#{navid},"result":{"frameId":"F","loaderId":"NEW"}}))

      FakeCDP.send_text(
        fake,
        ~s({"method":"Page.lifecycleEvent","params":{"name":"networkAlmostIdle","loaderId":"OLD","frameId":"F"}})
      )

      refute Task.yield(task, 200), "navigate resolved on another loader's milestone"

      # This navigation's own milestone ends the wait (on the default 30s timeout, so
      # only a real match keeps Task.await/2 inside its 2s budget).
      FakeCDP.send_text(
        fake,
        ~s({"method":"Page.lifecycleEvent","params":{"name":"networkAlmostIdle","loaderId":"NEW","frameId":"F"}})
      )

      assert {:ok, %Page{}} = Task.await(task, 2_000)
    end

    test "ignores a sub-frame's milestone (frameId mismatch)", %{page: page, conn: conn, fake: fake} do
      # frameId is the correlation guard that stays active when an event carries no
      # loaderId (Page.navigate always returns frameId; only loaderId is optional), so a
      # child frame's networkAlmostIdle must not end the main-frame wait.
      task = Task.async(fn -> Page.navigate(page, "http://example.test/") end)
      wait_until_subscribed(conn, task.pid)

      assert_receive {:fake_cdp_recv, ^fake, %{"id" => navid, "method" => "Page.navigate"}}, 2_000
      FakeCDP.send_text(fake, ~s({"id":#{navid},"result":{"frameId":"F","loaderId":"NEW"}}))

      FakeCDP.send_text(
        fake,
        ~s({"method":"Page.lifecycleEvent","params":{"name":"networkAlmostIdle","frameId":"SUB"}})
      )

      refute Task.yield(task, 200), "navigate resolved on a sub-frame's milestone"

      FakeCDP.send_text(
        fake,
        ~s({"method":"Page.lifecycleEvent","params":{"name":"networkAlmostIdle","loaderId":"NEW","frameId":"F"}})
      )

      assert {:ok, %Page{}} = Task.await(task, 2_000)
    end

    test "resolves on a successor document's milestone (client-side redirect)", %{
      page: page,
      conn: conn,
      fake: fake
    } do
      # A meta refresh / JS location change replaces the navigated document with a NEW
      # loader before it goes network-quiet; the original loader's networkAlmostIdle
      # never fires (its document is gone). Once our document has committed (its `init`
      # arrived), an `init` on the same frame with another loaderId is that successor —
      # its milestone must end the wait, not the 30s ceiling.
      task = Task.async(fn -> Page.navigate(page, "http://example.test/") end)
      wait_until_subscribed(conn, task.pid)

      assert_receive {:fake_cdp_recv, ^fake, %{"id" => navid, "method" => "Page.navigate"}}, 2_000
      FakeCDP.send_text(fake, ~s({"id":#{navid},"result":{"frameId":"F","loaderId":"L1"}}))

      for name <- ["init", "load"] do
        FakeCDP.send_text(
          fake,
          ~s({"method":"Page.lifecycleEvent","params":{"name":"#{name}","loaderId":"L1","frameId":"F"}})
        )
      end

      for name <- ["init", "load", "networkAlmostIdle"] do
        FakeCDP.send_text(
          fake,
          ~s({"method":"Page.lifecycleEvent","params":{"name":"#{name}","loaderId":"L2","frameId":"F"}})
        )
      end

      assert {:ok, %Page{}} = Task.await(task, 2_000)
    end

    test "a predecessor's init + milestone before our document commits is still stale", %{
      page: page,
      conn: conn,
      fake: fake
    } do
      # Successor detection must be gated on OUR document having committed: a
      # replayed/late `init` for the previous loader arriving before our `init` is a
      # predecessor, not a successor, and its milestone must not end the wait.
      task = Task.async(fn -> Page.navigate(page, "http://example.test/") end)
      wait_until_subscribed(conn, task.pid)

      assert_receive {:fake_cdp_recv, ^fake, %{"id" => navid, "method" => "Page.navigate"}}, 2_000
      FakeCDP.send_text(fake, ~s({"id":#{navid},"result":{"frameId":"F","loaderId":"NEW"}}))

      for name <- ["init", "networkAlmostIdle"] do
        FakeCDP.send_text(
          fake,
          ~s({"method":"Page.lifecycleEvent","params":{"name":"#{name}","loaderId":"OLD","frameId":"F"}})
        )
      end

      refute Task.yield(task, 200), "navigate resolved on a predecessor's milestone"

      for name <- ["init", "networkAlmostIdle"] do
        FakeCDP.send_text(
          fake,
          ~s({"method":"Page.lifecycleEvent","params":{"name":"#{name}","loaderId":"NEW","frameId":"F"}})
        )
      end

      assert {:ok, %Page{}} = Task.await(task, 2_000)
    end
  end

  describe "a :session page whose session detaches mid-wait (#121)" do
    setup %{page: page} do
      %{page: %{page | session_id: "S"}}
    end

    test "wait_for_navigation/2 ends on its own session's detach, not another's", %{
      page: page,
      conn: conn,
      fake: fake
    } do
      task = Task.async(fn -> Page.wait_for_navigation(page, timeout: 5_000) end)
      wait_until_any_subscribed(conn, "Target.detachedFromTarget")
      answer_probe(fake)

      send_detach(fake, "OTHER")
      refute Task.yield(task, 100), "another session's detach ended the wait"

      send_detach(fake, "S")
      assert {:error, {:session_closed, "S"}} = Task.await(task, 1_000)
      # The watcher is gone, and Connection pruned its subscription.
      wait_until_subscriber_count_below(conn, "Target.detachedFromTarget", 1)
    end

    test "wait_for_navigation/2 leaves the caller's own detach subscription and events alone", %{
      page: page,
      conn: conn,
      fake: fake
    } do
      :ok = Connection.subscribe(conn, "Target.detachedFromTarget")
      send_detach(fake, "QUEUED")
      assert_receive {:cdp_event, ^conn, "Target.detachedFromTarget", _, _} = queued, 2_000
      send(self(), queued)

      # The wait runs in this process, beside its subscription, so the milestone
      # that ends it has to come from elsewhere.
      caller = self()

      spawn_link(fn ->
        wait_until_subscribed(conn, caller)
        answer_pending_probe(conn, fake)

        FakeCDP.send_text(
          fake,
          ~s({"method":"Page.lifecycleEvent","sessionId":"S","params":{"name":"networkAlmostIdle"}})
        )
      end)

      assert :ok = Page.wait_for_navigation(page, timeout: 2_000)
      assert_received ^queued

      send_detach(fake, "LATER")

      assert_receive {:cdp_event, ^conn, "Target.detachedFromTarget", %{"sessionId" => "LATER"}, _},
                     2_000
    end

    test "wait_for_navigation/2 on an already-detached session returns at once", %{
      page: page,
      fake: fake
    } do
      task = Task.async(fn -> Page.wait_for_navigation(page, timeout: 5_000) end)

      assert_receive {:fake_cdp_recv, ^fake, %{"id" => id, "sessionId" => "S"}}, 2_000

      FakeCDP.send_text(
        fake,
        ~s({"id":#{id},"error":{"code":-32001,"message":"Session with given id not found."}})
      )

      assert {:error, {:session_closed, "S"}} = Task.await(task, 1_000)
    end

    test "an unanswered probe delays wait_for_navigation/2 by its cap, not the timeout", %{
      page: page,
      fake: fake
    } do
      task =
        Task.async(fn -> :timer.tc(fn -> Page.wait_for_navigation(page, timeout: 6_000) end) end)

      assert_receive {:fake_cdp_recv, ^fake, %{"method" => "Target.getTargetInfo"}}, 2_000

      FakeCDP.send_text(
        fake,
        ~s({"method":"Page.lifecycleEvent","sessionId":"S","params":{"name":"networkAlmostIdle"}})
      )

      assert {elapsed_us, :ok} = Task.await(task, 7_000)
      assert elapsed_us < 4_000_000
    end

    test "a detach that loses the race to the milestone leaves no message behind", %{
      page: page,
      conn: conn,
      fake: fake
    } do
      task =
        Task.async(fn ->
          result = Page.wait_for_navigation(page, timeout: 5_000)
          {result, Process.info(self(), :messages)}
        end)

      wait_until_any_subscribed(conn, "Target.detachedFromTarget")
      answer_probe(fake)
      true = :erlang.suspend_process(task.pid)

      FakeCDP.send_text(
        fake,
        ~s({"method":"Page.lifecycleEvent","sessionId":"S","params":{"name":"networkAlmostIdle"}})
      )

      send_detach(fake, "S")
      # The watcher has forwarded the detach and exited once its subscription is pruned.
      wait_until_subscriber_count_below(conn, "Target.detachedFromTarget", 1)
      true = :erlang.resume_process(task.pid)

      assert {:ok, {:messages, []}} = Task.await(task, 1_000)
    end

    test "navigate/3 ends its readiness wait on the detach, as an error", %{
      page: page,
      conn: conn,
      fake: fake
    } do
      task = Task.async(fn -> Page.navigate(page, "http://example.test/", timeout: 5_000) end)
      wait_until_any_subscribed(conn, "Target.detachedFromTarget")

      assert_receive {:fake_cdp_recv, ^fake, %{"id" => navid, "method" => "Page.navigate"}}, 2_000
      FakeCDP.send_text(fake, ~s({"id":#{navid},"sessionId":"S","result":{"loaderId":"L"}}))

      send_detach(fake, "S")
      assert {:error, {:session_closed, "S"}} = Task.await(task, 1_000)
    end

    test "wait_for_response/3 ends on the detach", %{page: page, conn: conn, fake: fake} do
      task = Task.async(fn -> Page.wait_for_response(page, "/api", timeout: 5_000) end)

      assert_receive {:fake_cdp_recv, ^fake, %{"id" => nid, "method" => "Network.enable"}}, 2_000
      FakeCDP.send_text(fake, ~s({"id":#{nid},"sessionId":"S","result":{}}))
      wait_until_waiting(conn)

      send_detach(fake, "S")
      assert {:error, {:session_closed, "S"}} = Task.await(task, 1_000)
    end

    test "wait_for_response/3 :trigger catches a detach while the trigger runs", %{
      page: page,
      conn: conn,
      fake: fake
    } do
      trigger = fn ->
        send_detach(fake, "S")
        sync_dispatch(conn, fake)
      end

      task =
        Task.async(fn -> Page.wait_for_response(page, "/api", trigger: trigger, timeout: 5_000) end)

      answer_network_enable(fake)
      assert {:error, {:session_closed, "S"}} = Task.await(task, 2_000)
    end

    test "wait_for_response/3 :trigger catches a detach right behind the Network.enable reply",
         %{page: page, fake: fake} do
      task =
        Task.async(fn ->
          Page.wait_for_response(page, "/api", trigger: fn -> :ok end, timeout: 5_000)
        end)

      answer_network_enable(fake)
      send_detach(fake, "S")
      assert {:error, {:session_closed, "S"}} = Task.await(task, 2_000)
    end

    test "wait_for_response/3 :trigger ends on a detach after the trigger", %{
      page: page,
      fake: fake
    } do
      test = self()

      task =
        Task.async(fn ->
          Page.wait_for_response(page, "/api",
            trigger: fn -> send(test, :triggered) end,
            timeout: 5_000
          )
        end)

      answer_network_enable(fake)
      assert_receive :triggered, 2_000

      send_detach(fake, "S")
      assert {:error, {:session_closed, "S"}} = Task.await(task, 2_000)
    end

    # The task is suspended while the enable reply and then the detach reach its
    # mailbox, so it sees the enable succeed with the budget already spent.
    test "wait_for_response/3 :trigger reports a detach that arrived before the budget ran out",
         %{page: page, conn: conn, fake: fake} do
      test = self()

      task =
        Task.async(fn ->
          Page.wait_for_response(page, "/api",
            trigger: fn -> send(test, :triggered) end,
            timeout: 1_000
          )
        end)

      assert_receive {:fake_cdp_recv, ^fake, %{"id" => nid, "method" => "Network.enable"}}, 2_000
      true = :erlang.suspend_process(task.pid)
      FakeCDP.send_text(fake, ~s({"id":#{nid},"sessionId":"S","result":{}}))
      sync_dispatch(conn, fake)
      send_detach(fake, "S")
      sync_dispatch(conn, fake)
      Process.sleep(1_100)
      true = :erlang.resume_process(task.pid)

      assert {:error, {:session_closed, "S"}} = Task.await(task, 2_000)
      refute_received :triggered
    end

    test "navigate/3 with response: true ends on the detach", %{page: page, conn: conn, fake: fake} do
      task =
        Task.async(fn ->
          Page.navigate(page, "http://example.test/", response: true, timeout: 5_000)
        end)

      assert_receive {:fake_cdp_recv, ^fake, %{"id" => nid, "method" => "Network.enable"}}, 2_000
      FakeCDP.send_text(fake, ~s({"id":#{nid},"sessionId":"S","result":{}}))
      wait_until_any_subscribed(conn, "Target.detachedFromTarget")

      assert_receive {:fake_cdp_recv, ^fake, %{"id" => navid, "method" => "Page.navigate"}}, 2_000
      FakeCDP.send_text(fake, ~s({"id":#{navid},"sessionId":"S","result":{"loaderId":"L"}}))

      send_detach(fake, "S")
      assert {:error, {:session_closed, "S"}} = Task.await(task, 1_000)
    end

    test "wait_for_network_idle/2 ends on the detach", %{page: page, conn: conn, fake: fake} do
      task =
        Task.async(fn -> Page.wait_for_network_idle(page, idle_time: 5_000, timeout: 8_000) end)

      assert_receive {:fake_cdp_recv, ^fake, %{"id" => nid, "method" => "Network.enable"}}, 2_000
      FakeCDP.send_text(fake, ~s({"id":#{nid},"sessionId":"S","result":{}}))
      wait_until_any_subscribed(conn, "Target.detachedFromTarget")

      send_detach(fake, "S")
      assert {:error, {:session_closed, "S"}} = Task.await(task, 1_000)
    end
  end

  describe "navigate/3 with response: true" do
    test "a dedicated page never subscribes to the detach", %{page: page, conn: conn, fake: fake} do
      task = Task.async(fn -> Page.navigate(page, "http://example.test/", response: true) end)

      answer_network_enable(fake)
      wait_until_any_subscribed(conn, "Network.responseReceived")
      wait_until_any_subscribed(conn, "Page.lifecycleEvent")
      assert subscriber_count(conn, "Target.detachedFromTarget") == 0

      assert_receive {:fake_cdp_recv, ^fake, %{"id" => navid, "method" => "Page.navigate"}}, 2_000
      FakeCDP.send_text(fake, ~s({"id":#{navid},"result":{"frameId":"F","loaderId":"L"}}))

      FakeCDP.send_text(
        fake,
        ~s({"method":"Network.responseReceived","params":{"type":"Document","loaderId":"L","frameId":"F","response":{"status":200,"url":"http://example.test/"}}})
      )

      FakeCDP.send_text(
        fake,
        ~s({"method":"Page.lifecycleEvent","params":{"name":"networkAlmostIdle"}})
      )

      assert {:ok, %Page{}, _response} = Task.await(task, 2_000)
    end

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

    test "ignores a stale milestone from a previous loader (late about:blank idle)", %{
      page: page,
      conn: conn,
      fake: fake
    } do
      # Chrome emits networkAlmostIdle for the pre-navigation about:blank document ~500ms
      # after the target is created (and replays it on Page.setLifecycleEventsEnabled) —
      # carrying the OLD loaderId, often ahead of our document response in the mailbox.
      # Closing the capture window on it loses the real status.
      task =
        Task.async(fn ->
          Page.navigate(page, "http://example.test/missing", response: true, timeout: 1_000)
        end)

      assert_receive {:fake_cdp_recv, ^fake, %{"id" => nid, "method" => "Network.enable"}}, 2_000
      FakeCDP.send_text(fake, ~s({"id":#{nid},"result":{}}))

      wait_until_any_subscribed(conn, "Network.responseReceived")
      wait_until_any_subscribed(conn, "Page.lifecycleEvent")

      assert_receive {:fake_cdp_recv, ^fake, %{"id" => navid, "method" => "Page.navigate"}}, 2_000

      # Queued before the navigate reply, so the stale milestone sits at the head of the
      # helper's mailbox — ahead of this navigation's document response.
      FakeCDP.send_text(
        fake,
        ~s({"method":"Page.lifecycleEvent","params":{"name":"networkAlmostIdle","loaderId":"OLD","frameId":"F"}})
      )

      FakeCDP.send_text(fake, ~s({"id":#{navid},"result":{"frameId":"F","loaderId":"NEW"}}))

      FakeCDP.send_text(
        fake,
        ~s({"method":"Network.responseReceived","params":{"type":"Document","loaderId":"NEW","frameId":"F","response":{"status":404,"url":"http://example.test/missing"}}})
      )

      FakeCDP.send_text(
        fake,
        ~s({"method":"Page.lifecycleEvent","params":{"name":"networkAlmostIdle","loaderId":"NEW","frameId":"F"}})
      )

      assert {:ok, %Page{}, %{status: 404, url: "http://example.test/missing"}} =
               Task.await(task, 2_000)
    end

    test "a navigation with no loaderId still ends on the milestone (no hang)", %{
      page: page,
      conn: conn,
      fake: fake
    } do
      # Page.navigate's loaderId is optional per the CDP spec. Correlation only *rejects*
      # a milestone when both sides carry a loaderId and they differ — an absent id must
      # never make the milestone unmatchable, which would turn this prompt miss into a
      # 30s timeout. The document response stays strictly correlated, so nothing is
      # captured here and the call reports the miss (on the default 30s timeout, so only
      # a prompt return keeps Task.await/2 inside its 2s budget).
      task = Task.async(fn -> Page.navigate(page, "http://example.test/", response: true) end)

      assert_receive {:fake_cdp_recv, ^fake, %{"id" => nid, "method" => "Network.enable"}}, 2_000
      FakeCDP.send_text(fake, ~s({"id":#{nid},"result":{}}))

      wait_until_any_subscribed(conn, "Network.responseReceived")
      wait_until_any_subscribed(conn, "Page.lifecycleEvent")

      assert_receive {:fake_cdp_recv, ^fake, %{"id" => navid, "method" => "Page.navigate"}}, 2_000
      FakeCDP.send_text(fake, ~s({"id":#{navid},"result":{"frameId":"F"}}))

      FakeCDP.send_text(
        fake,
        ~s({"method":"Page.lifecycleEvent","params":{"name":"networkAlmostIdle","loaderId":"NEW","frameId":"F"}})
      )

      assert {:error, {:no_document_response, "http://example.test/"}} = Task.await(task, 2_000)
    end

    test "a successor document's milestone ends the capture; the response stays this navigation's",
         %{page: page, conn: conn, fake: fake} do
      # Client-side redirect with response: true — the successor's networkAlmostIdle ends
      # the wait promptly (not at the deadline), while %{status, url} keeps reporting
      # THIS navigation's document (L1), the pre-#106 behaviour: the successor is a new
      # navigation, not a redirect hop of this one.
      task = Task.async(fn -> Page.navigate(page, "http://example.test/start", response: true) end)

      assert_receive {:fake_cdp_recv, ^fake, %{"id" => nid, "method" => "Network.enable"}}, 2_000
      FakeCDP.send_text(fake, ~s({"id":#{nid},"result":{}}))

      wait_until_any_subscribed(conn, "Network.responseReceived")
      wait_until_any_subscribed(conn, "Page.lifecycleEvent")

      assert_receive {:fake_cdp_recv, ^fake, %{"id" => navid, "method" => "Page.navigate"}}, 2_000
      FakeCDP.send_text(fake, ~s({"id":#{navid},"result":{"frameId":"F","loaderId":"L1"}}))

      FakeCDP.send_text(
        fake,
        ~s({"method":"Network.responseReceived","params":{"type":"Document","loaderId":"L1","frameId":"F","response":{"status":200,"url":"http://example.test/start"}}})
      )

      FakeCDP.send_text(
        fake,
        ~s({"method":"Page.lifecycleEvent","params":{"name":"init","loaderId":"L1","frameId":"F"}})
      )

      # The successor's document response precedes its init (headers, then commit).
      FakeCDP.send_text(
        fake,
        ~s({"method":"Network.responseReceived","params":{"type":"Document","loaderId":"L2","frameId":"F","response":{"status":200,"url":"http://example.test/final"}}})
      )

      for name <- ["init", "networkAlmostIdle"] do
        FakeCDP.send_text(
          fake,
          ~s({"method":"Page.lifecycleEvent","params":{"name":"#{name}","loaderId":"L2","frameId":"F"}})
        )
      end

      assert {:ok, %Page{}, %{status: 200, url: "http://example.test/start"}} =
               Task.await(task, 2_000)
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

  describe "wait_for_response/3 :trigger (#126)" do
    test "catches a response that arrives while the trigger is still running", %{
      page: page,
      conn: conn,
      fake: fake
    } do
      # The response is dispatched before the trigger returns, so only a wait
      # registered before the trigger ran can see it.
      trigger = fn ->
        send_response(fake, "R1", "http://x/api/data")
        sync_dispatch(conn, fake)
        {:ok, %{}}
      end

      task =
        Task.async(fn ->
          Page.wait_for_response(page, "/api/data", trigger: trigger, timeout: 2_000)
        end)

      answer_network_enable(fake)
      assert {:ok, %{"requestId" => "R1"}} = Task.await(task, 3_000)
      assert waiter_count(conn) == 0
    end

    test "waits for a response that arrives after the trigger", %{
      page: page,
      fake: fake
    } do
      test = self()

      task =
        Task.async(fn ->
          Page.wait_for_response(page, "/api/data",
            trigger: fn -> send(test, :triggered) end,
            timeout: 2_000
          )
        end)

      answer_network_enable(fake)
      assert_receive :triggered, 2_000

      send_response(fake, "R0", "http://x/other")
      send_response(fake, "R1", "http://x/api/data")
      assert {:ok, %{"requestId" => "R1"}} = Task.await(task, 3_000)
    end

    test "returns the trigger's {:error, _} without waiting, and drops the wait", %{
      page: page,
      conn: conn,
      fake: fake
    } do
      task =
        Task.async(fn ->
          result =
            Page.wait_for_response(page, "/api",
              trigger: fn -> {:error, :not_clicked} end,
              timeout: 5_000
            )

          {result, leftovers(conn, fake)}
        end)

      answer_network_enable(fake)
      assert {{:error, :not_clicked}, []} = Task.await(task, 1_000)
      eventually(fn -> waiter_count(conn) == 0 end)
    end

    test "a response that matched while the trigger ran beats the trigger's {:error, _}", %{
      page: page,
      conn: conn,
      fake: fake
    } do
      trigger = fn ->
        send_response(fake, "R1", "http://x/api/data")
        sync_dispatch(conn, fake)
        {:error, :late_click_error}
      end

      task =
        Task.async(fn ->
          result = Page.wait_for_response(page, "/api/data", trigger: trigger, timeout: 2_000)
          {result, leftovers(conn, fake)}
        end)

      answer_network_enable(fake)
      assert {{:ok, %{"requestId" => "R1"}}, []} = Task.await(task, 3_000)
      eventually(fn -> waiter_count(conn) == 0 end)
    end

    test "a raise in the trigger propagates and leaves no wait or message behind", %{
      page: page,
      conn: conn,
      fake: fake
    } do
      task =
        Task.async(fn ->
          raised =
            try do
              Page.wait_for_response(page, "/api", trigger: fn -> raise "boom" end)
            rescue
              e in RuntimeError -> e
            end

          {raised, leftovers(conn, fake)}
        end)

      answer_network_enable(fake)
      assert {%RuntimeError{message: "boom"}, []} = Task.await(task, 2_000)
      eventually(fn -> waiter_count(conn) == 0 end)
    end

    test "a throw in the trigger propagates and leaves no wait or message behind", %{
      page: page,
      conn: conn,
      fake: fake
    } do
      task =
        Task.async(fn ->
          thrown =
            catch_throw(Page.wait_for_response(page, "/api", trigger: fn -> throw(:boom) end))

          {thrown, leftovers(conn, fake)}
        end)

      answer_network_enable(fake)
      assert {:boom, []} = Task.await(task, 2_000)
      eventually(fn -> waiter_count(conn) == 0 end)
    end

    test "an exit in the trigger propagates", %{page: page, fake: fake} do
      task =
        Task.async(fn ->
          catch_exit(Page.wait_for_response(page, "/api", trigger: fn -> exit(:boom) end))
        end)

      answer_network_enable(fake)
      assert :boom = Task.await(task, 2_000)
    end

    test "the trigger's run time counts against :timeout", %{page: page, conn: conn, fake: fake} do
      trigger = fn -> Process.sleep(200) end

      task =
        Task.async(fn ->
          :timer.tc(fn -> Page.wait_for_response(page, "/api", trigger: trigger, timeout: 300) end)
        end)

      answer_network_enable(fake)
      assert {elapsed_us, {:error, :timeout}} = Task.await(task, 2_000)
      assert elapsed_us < 600_000
      eventually(fn -> waiter_count(conn) == 0 end)
    end

    # The call returns when the trigger does (~300ms), not a fresh :timeout
    # after it (~600ms).
    test "a trigger that runs past :timeout is not interrupted, then the call times out", %{
      page: page,
      conn: conn,
      fake: fake
    } do
      trigger = fn -> Process.sleep(300) end

      task =
        Task.async(fn ->
          {elapsed_us, result} =
            :timer.tc(fn ->
              Page.wait_for_response(page, "/api", trigger: trigger, timeout: 300)
            end)

          {elapsed_us, result, leftovers(conn, fake)}
        end)

      answer_network_enable(fake)
      assert {elapsed_us, {:error, :timeout}, []} = Task.await(task, 2_000)
      assert elapsed_us >= 300_000
      assert elapsed_us < 550_000
      eventually(fn -> waiter_count(conn) == 0 end)
    end

    test "a trigger that runs past :timeout still returns a response that matched while it ran",
         %{page: page, conn: conn, fake: fake} do
      trigger = fn ->
        send_response(fake, "R1", "http://x/api/data")
        sync_dispatch(conn, fake)
        Process.sleep(300)
      end

      task =
        Task.async(fn ->
          result = Page.wait_for_response(page, "/api/data", trigger: trigger, timeout: 200)
          {result, leftovers(conn, fake)}
        end)

      answer_network_enable(fake)
      assert {{:ok, %{"requestId" => "R1"}}, []} = Task.await(task, 2_000)
      assert waiter_count(conn) == 0
    end

    test "errors if the connection drops while waiting", %{page: page, conn: conn, fake: fake} do
      test = self()

      task =
        Task.async(fn ->
          Page.wait_for_response(page, "/never",
            trigger: fn -> send(test, :triggered) end,
            timeout: 3_000
          )
        end)

      answer_network_enable(fake)
      assert_receive :triggered, 2_000
      Connection.close(conn)

      assert {:error, reason} = Task.await(task, 2_000)
      assert reason == :noproc or match?({:ws_closed, _}, reason)
    end

    test "returns {:error, :noproc} if the connection is killed while waiting", %{
      page: page,
      conn: conn,
      fake: fake
    } do
      test = self()

      task =
        Task.async(fn ->
          Page.wait_for_response(page, "/never",
            trigger: fn -> send(test, :triggered) end,
            timeout: 3_000
          )
        end)

      answer_network_enable(fake)
      assert_receive :triggered, 2_000
      Process.exit(conn, :kill)

      assert {:error, :noproc} = Task.await(task, 2_000)
    end

    test "a stalled connection can't hold the call past :timeout", %{
      page: page,
      conn: conn,
      fake: fake
    } do
      task =
        Task.async(fn ->
          :timer.tc(fn ->
            Page.wait_for_response(page, "/api",
              trigger: fn -> :sys.suspend(conn) end,
              timeout: 300
            )
          end)
        end)

      answer_network_enable(fake)
      assert {elapsed_us, {:error, :timeout}} = Task.await(task, 2_000)
      assert elapsed_us < 600_000
      :sys.resume(conn)
    end

    test "a connection stalled before registration can't hold the call past :timeout", %{
      page: page,
      conn: conn
    } do
      test = self()
      :sys.suspend(conn)

      {elapsed_us, result} =
        :timer.tc(fn ->
          Page.wait_for_response(page, "/api",
            trigger: fn -> send(test, :triggered) end,
            timeout: 300
          )
        end)

      :sys.resume(conn)
      assert result == {:error, :timeout}
      assert elapsed_us < 700_000
      refute_received :triggered
      eventually(fn -> waiter_count(conn) == 0 end)
    end

    # The enable reply is queued ahead of the timeout while the connection is
    # suspended, so the enable succeeds with the budget already spent.
    test "doesn't run the trigger once Network.enable has used up :timeout", %{
      page: page,
      conn: conn,
      fake: fake
    } do
      test = self()

      task =
        Task.async(fn ->
          Page.wait_for_response(page, "/api",
            trigger: fn -> send(test, :triggered) end,
            timeout: 200
          )
        end)

      assert_receive {:fake_cdp_recv, ^fake, %{"id" => nid, "method" => "Network.enable"}}, 2_000
      :sys.suspend(conn)
      FakeCDP.send_text(fake, ~s({"id":#{nid},"result":{}}))
      Process.sleep(300)
      :sys.resume(conn)

      assert {:error, :timeout} = Task.await(task, 2_000)
      refute_received :triggered
      eventually(fn -> waiter_count(conn) == 0 end)
    end

    test "a match that arrived during Network.enable wins even once :timeout is spent", %{
      page: page,
      conn: conn,
      fake: fake
    } do
      test = self()

      task =
        Task.async(fn ->
          Page.wait_for_response(page, "/api/data",
            trigger: fn -> send(test, :triggered) end,
            timeout: 200
          )
        end)

      assert_receive {:fake_cdp_recv, ^fake, %{"id" => nid, "method" => "Network.enable"}}, 2_000
      send_response(fake, "R1", "http://x/api/data")
      sync_dispatch(conn, fake)
      :sys.suspend(conn)
      FakeCDP.send_text(fake, ~s({"id":#{nid},"result":{}}))
      Process.sleep(300)
      :sys.resume(conn)

      assert {:ok, %{"requestId" => "R1"}} = Task.await(task, 2_000)
      refute_received :triggered
      eventually(fn -> waiter_count(conn) == 0 end)
    end

    test "an unanswered Network.enable is {:error, :timeout}, with or without :trigger", %{
      page: page
    } do
      test = self()
      assert Page.wait_for_response(page, "/api", timeout: 150) == {:error, :timeout}

      assert Page.wait_for_response(page, "/api",
               trigger: fn -> send(test, :triggered) end,
               timeout: 150
             ) == {:error, :timeout}

      refute_received :triggered
    end

    test "a match that arrived during an unanswered Network.enable still wins", %{
      page: page,
      conn: conn,
      fake: fake
    } do
      test = self()

      task =
        Task.async(fn ->
          Page.wait_for_response(page, "/api/data",
            trigger: fn -> send(test, :triggered) end,
            timeout: 300
          )
        end)

      assert_receive {:fake_cdp_recv, ^fake, %{"method" => "Network.enable"}}, 2_000
      send_response(fake, "R1", "http://x/api/data")
      sync_dispatch(conn, fake)

      assert {:ok, %{"requestId" => "R1"}} = Task.await(task, 2_000)
      refute_received :triggered
      eventually(fn -> waiter_count(conn) == 0 end)
    end

    test "returns a Network.enable failure without running the trigger", %{page: page, fake: fake} do
      test = self()

      task =
        Task.async(fn ->
          Page.wait_for_response(page, "/api",
            trigger: fn -> send(test, :triggered) end,
            timeout: 2_000
          )
        end)

      assert_receive {:fake_cdp_recv, ^fake, %{"id" => nid, "method" => "Network.enable"}}, 2_000
      FakeCDP.send_text(fake, ~s({"id":#{nid},"error":{"code":-32000,"message":"nope"}}))

      assert {:error, {:cdp_error, "Network.enable", _}} = Task.await(task, 1_000)
      refute_received :triggered
    end

    test "rejects a :trigger that isn't a 0-arity function before any CDP call", %{
      page: page,
      fake: fake
    } do
      for bad <- [fn _ -> :ok end, :click, "fn"] do
        assert_raise ArgumentError, ~r/invalid :trigger/, fn ->
          Page.wait_for_response(page, "/api", trigger: bad)
        end
      end

      refute_receive {:fake_cdp_recv, ^fake, _}, 50
    end
  end

  describe "wait_for_network_idle/2" do
    # The idle helper announces the moment it stops setting up and starts
    # counting; `enable_network_idle/2` waits for that instead of guessing at it
    # with a sleep, so a slow machine cannot land an event in the setup window.
    setup do
      handler = "idle-watching-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler,
        [:cdp_ex, :network_idle, :watching],
        &__MODULE__.forward_idle_watching/4,
        self()
      )

      on_exit(fn -> :telemetry.detach(handler) end)
    end

    test "an unanswered Network.enable is {:error, :timeout}", %{page: page} do
      assert Page.wait_for_network_idle(page, idle_time: 100, timeout: 200) == {:error, :timeout}
    end

    test "a dedicated page never subscribes to the detach", %{page: page, conn: conn, fake: fake} do
      task = Task.async(fn -> Page.wait_for_network_idle(page, idle_time: 100, timeout: 2_000) end)
      enable_network_idle(fake, conn)

      assert subscriber_count(conn, "Target.detachedFromTarget") == 0
      assert :ok = Task.await(task, 2_000)
    end

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
             await_cdp_events(conn, "Network.requestWillBeSent")}
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
    Map.has_key?(Map.get(:sys.get_state(conn).subscribers, method, %{}), pid)
  end

  # Like wait_until_subscribed/3 but matches *any* subscriber — used where the subscriber
  # is an internal helper process whose pid the test can't name (e.g. the response-capture
  # helper in navigate(response: true), #42).
  defp wait_until_any_subscribed(conn, method, retries \\ 100),
    do: wait_until_subscriber_count(conn, method, 1, retries)

  defp wait_until_subscriber_count_below(conn, method, count, retries \\ 100) do
    cond do
      map_size(Map.get(:sys.get_state(conn).subscribers, method, %{})) < count ->
        :ok

      retries == 0 ->
        flunk("#{method} still has #{count} or more subscribers")

      true ->
        Process.sleep(10)
        wait_until_subscriber_count_below(conn, method, count, retries - 1)
    end
  end

  defp subscriber_count(conn, method),
    do: map_size(Map.get(:sys.get_state(conn).subscribers, method, %{}))

  # Poll until `method` has at least `count` distinct subscriber pids.
  defp wait_until_subscriber_count(conn, method, count, retries \\ 100) do
    cond do
      map_size(Map.get(:sys.get_state(conn).subscribers, method, %{})) >= count ->
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
      map_size(Map.get(:sys.get_state(conn).subscribers, method, %{})) == 0 ->
        :ok

      retries == 0 ->
        flunk("subscribers for #{method} not pruned in time")

      true ->
        Process.sleep(10)
        wait_until_no_subscribers(conn, method, retries - 1)
    end
  end

  # Wait for the observer's copy of `method`, then take whatever else has queued. A
  # snapshot races here: the idle helper drops events arriving before it enters its
  # counting loop (page.ex pre-loop drain), so it can resolve in the same instant the
  # connection is fanning the copy out. That lost the event one run in sixty.
  defp await_cdp_events(conn, method, timeout \\ 2_000) do
    receive do
      {:cdp_event, ^conn, ^method, params, _sid} -> drain_cdp_events(conn, method, [params])
    after
      timeout -> []
    end
  end

  # Every buffered `method` cdp_event already in this process's mailbox, as params maps.
  # `after 0` is sound only where delivery is causally ordered before the caller unblocks —
  # the navigate/#42 call site, where the helper captures the same fan-out that enqueued the
  # observer's copy. Where that ordering is not guaranteed, use `await_cdp_events/3`.
  @doc false
  def forward_idle_watching(_event, _measurements, metadata, test_pid) do
    send(test_pid, {:idle_watching, metadata})
  end

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
    # Wait for the helper to finish its pre-loop drain and start counting, or an
    # event sent next would be discarded as setup noise rather than tracked.
    if conn, do: assert_receive({:idle_watching, _meta}, 2_000)
  end

  # wait_for_navigation/2's round trip on a :session page, answered as a live session.
  defp answer_probe(fake) do
    assert_receive {:fake_cdp_recv, ^fake, %{"id" => id, "method" => "Target.getTargetInfo"}},
                   2_000

    FakeCDP.send_text(fake, ~s({"id":#{id},"sessionId":"S","result":{}}))
  end

  # answer_probe/1 for a process that isn't FakeCDP's controller: find the call in
  # the connection's pending map instead of the controller's mailbox.
  defp answer_pending_probe(conn, fake, retries \\ 100) do
    probe =
      Enum.find(:sys.get_state(conn).pending, fn {_id, entry} ->
        elem(entry, 1) == "Target.getTargetInfo"
      end)

    case probe do
      {id, _entry} ->
        FakeCDP.send_text(fake, ~s({"id":#{id},"sessionId":"S","result":{}}))

      nil when retries > 0 ->
        Process.sleep(10)
        answer_pending_probe(conn, fake, retries - 1)
    end
  end

  defp send_response(fake, request_id, url) do
    FakeCDP.send_text(
      fake,
      ~s({"method":"Network.responseReceived","params":{"requestId":"#{request_id}","response":{"url":"#{url}","status":200}}})
    )
  end

  # Returns once the connection has dispatched every frame sent before it: frames
  # are handled in order, so a marker event coming back means the earlier ones
  # reached every waiter registered at the time.
  defp sync_dispatch(conn, fake) do
    :ok = Connection.subscribe(conn, "Test.marker")
    FakeCDP.send_text(fake, ~s({"method":"Test.marker","params":{}}))
    assert_receive {:cdp_event, ^conn, "Test.marker", _, _}, 2_000
    Connection.unsubscribe(conn, "Test.marker")
  end

  # What a finished wait left in this process's mailbox, after a late matching
  # response has had every chance to arrive.
  defp leftovers(conn, fake) do
    send_response(fake, "LATE", "http://x/api")
    sync_dispatch(conn, fake)
    {:messages, messages} = Process.info(self(), :messages)
    messages
  end

  defp waiter_count(conn), do: length(:sys.get_state(conn).waiters)

  defp eventually(fun, retries \\ 100) do
    cond do
      fun.() -> :ok
      retries == 0 -> flunk("condition not met in time")
      true -> Process.sleep(10) && eventually(fun, retries - 1)
    end
  end

  # Untagged, as Chrome sends it: on the browser session that attached `sid`.
  defp send_detach(fake, sid) do
    FakeCDP.send_text(
      fake,
      ~s({"method":"Target.detachedFromTarget","params":{"sessionId":"#{sid}","targetId":"T"}})
    )
  end

  defp send_network_event(fake, method, request_id) do
    FakeCDP.send_text(fake, ~s({"method":"#{method}","params":{"requestId":"#{request_id}"}}))
  end

  defp reply_evaluate(fake, value) do
    assert_receive {:fake_cdp_recv, ^fake, %{"id" => id, "method" => "Runtime.evaluate"}}, 2_000
    FakeCDP.send_text(fake, evaluate_reply(id, value))
  end

  defp send_cdp_error(fake, message) do
    assert_receive {:fake_cdp_recv, ^fake, %{"id" => id, "method" => "Runtime.evaluate"}}, 2_000
    error = %{"code" => -32_000, "message" => message}
    FakeCDP.send_text(fake, Jason.encode!(%{"id" => id, "error" => error}))
  end

  defp evaluate_reply(id, value),
    do: Jason.encode!(%{"id" => id, "result" => %{"result" => %{"value" => value}}})

  # Answers every Runtime.evaluate with `value` until `task` returns; yields the task's
  # result and how many attempts it made.
  defp answer_until_done(task, fake, value, attempts \\ 0) do
    %Task{ref: ref} = task

    receive do
      {:fake_cdp_recv, ^fake, %{"id" => id, "method" => "Runtime.evaluate"}} ->
        FakeCDP.send_text(fake, evaluate_reply(id, value))
        answer_until_done(task, fake, value, attempts + 1)

      {^ref, result} ->
        Process.demonitor(ref, [:flush])
        {result, attempts}
    after
      5_000 -> flunk("task neither polled nor returned")
    end
  end

  defp assert_wait_for_selector_expression(page, fake, css, expected_js) do
    task = Task.async(fn -> Page.wait_for_selector(page, css, timeout: 2_000, interval: 10) end)

    assert_receive {:fake_cdp_recv, ^fake,
                    %{
                      "id" => id,
                      "method" => "Runtime.evaluate",
                      "params" => %{"expression" => expression}
                    }},
                   2_000

    assert expression == expected_js

    # Resolve the wait so the task exits cleanly rather than racing teardown.
    FakeCDP.send_text(
      fake,
      ~s({"id":#{id},"result":{"result":{"type":"boolean","value":true}}})
    )

    assert :ok = Task.await(task, 2_000)
  end
end
