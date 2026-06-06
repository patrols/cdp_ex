defmodule CDPEx.IntegrationTest do
  @moduledoc """
  End-to-end tests against a real headless Chrome. Excluded by default; run with
  `mix test --include integration` and Chrome available (set CDP_EX_CHROME_BINARY).

  Fixtures are served by a tiny local HTTP server (`CDPEx.FixtureServer`) rather
  than `data:` URLs — a real http:// origin gives Chrome a stable execution
  context and paint surface, which `data:` URLs do not (they flake `evaluate`,
  lifecycle waits, and screenshots in headless mode).
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias CDPEx.Browser
  alias CDPEx.Connection
  alias CDPEx.FixtureServer
  alias CDPEx.Page
  alias CDPEx.Pool
  alias CDPEx.ProxyAuthServer

  @moduletag :integration
  # Real Chrome launches are slower than the default 60s in aggregate.
  @moduletag timeout: 120_000

  setup_all do
    {:ok, %{url: fixture_url}} = FixtureServer.start()
    %{fixture: fixture_url}
  end

  # Browsers are linked to the test process (CDPEx.launch -> start_link). Trap
  # exits so a deliberately-killed Chrome surfaces as a message + monitor DOWN
  # rather than taking the test process down with it.
  setup do
    Process.flag(:trap_exit, true)
    :ok
  end

  describe "browser lifecycle" do
    test "launch/1 returns a live pid and stop/1 shuts it down" do
      assert {:ok, browser} = CDPEx.launch()
      assert is_pid(browser)
      assert Process.alive?(browser)

      ref = Process.monitor(browser)
      assert :ok = CDPEx.stop(browser)
      assert_receive {:DOWN, ^ref, :process, ^browser, _}, 5_000
    end

    test "launch/1 returns well under the timeout ceiling (readiness is polled)" do
      {elapsed_us, {:ok, browser}} = :timer.tc(fn -> CDPEx.launch() end)
      on_exit(fn -> stop_quietly(browser) end)
      # Real Chrome is reachable in ~1s locally; :launch_timeout (15s default) is a
      # ceiling, not a fixed wait. Assert comfortably under it (loose, non-flaky).
      assert elapsed_us < 10_000_000
    end

    test "new_page/2 then close_page/2" do
      {:ok, browser} = CDPEx.launch()
      on_exit(fn -> stop_quietly(browser) end)

      assert {:ok, %Page{} = page} = CDPEx.new_page(browser)
      assert is_pid(page.conn)
      assert is_binary(page.target_id)
      assert :ok = CDPEx.close_page(browser, page)
    end

    test "killing Chrome stops the browser and frees in-flight callers" do
      {:ok, browser} = CDPEx.launch()
      {:ok, page} = CDPEx.new_page(browser)
      ref = Process.monitor(browser)

      # Kill Chrome out from under us.
      %{chrome: %{os_pid: os_pid}} = :sys.get_state(browser)
      System.cmd("kill", ["-9", to_string(os_pid)])

      assert_receive {:DOWN, ^ref, :process, ^browser, _reason}, 10_000
      # The page handle's connection is gone too; ops fail rather than hang.
      assert {:error, _} = Page.evaluate(page, "1 + 1")
    end

    test "close_page rejects a page from another browser without harming it" do
      {:ok, browser_a} = CDPEx.launch()
      {:ok, browser_b} = CDPEx.launch()
      on_exit(fn -> stop_quietly(browser_a) end)
      on_exit(fn -> stop_quietly(browser_b) end)

      {:ok, page_b} = CDPEx.new_page(browser_b)

      # Closing B's page through A must refuse and must NOT stop B's page conn —
      # the handle's conn belongs to another browser.
      assert {:error, :unknown_page} = CDPEx.close_page(browser_a, page_b)
      assert Process.alive?(page_b.conn)

      # B still owns the page: it works and closes cleanly.
      assert {:ok, _} = Page.evaluate(page_b, "1 + 1")
      assert :ok = CDPEx.close_page(browser_b, page_b)
    end
  end

  describe "session transport" do
    test "two session pages share one browser connection and stay isolated", %{fixture: fixture} do
      {:ok, browser} = CDPEx.launch()
      on_exit(fn -> stop_quietly(browser) end)

      {:ok, p1} = CDPEx.new_page(browser, transport: :session)
      {:ok, p2} = CDPEx.new_page(browser, transport: :session)

      # Both ride the SAME browser connection, with distinct session ids.
      browser_conn = :sys.get_state(browser).browser_conn
      assert p1.conn == browser_conn and p2.conn == browser_conn
      assert is_binary(p1.session_id) and is_binary(p2.session_id)
      assert p1.session_id != p2.session_id
      assert map_size(:sys.get_state(browser).sessions) == 2

      {:ok, _} = Page.navigate(p1, fixture)
      {:ok, _} = Page.navigate(p2, fixture)

      # Separate execution contexts: a global set in one session is invisible to
      # the other (no cross-talk on the shared socket).
      assert {:ok, "one"} = Page.evaluate(p1, "window.__id = 'one'; window.__id")
      assert {:ok, "two"} = Page.evaluate(p2, "window.__id = 'two'; window.__id")
      assert {:ok, "one"} = Page.evaluate(p1, "window.__id")
      assert {:ok, "Hello"} = Page.text(p1, "#greeting")
    end

    test "closing a session page detaches it without harming siblings", %{fixture: fixture} do
      {:ok, browser} = CDPEx.launch()
      on_exit(fn -> stop_quietly(browser) end)

      {:ok, p1} = CDPEx.new_page(browser, transport: :session)
      {:ok, p2} = CDPEx.new_page(browser, transport: :session)
      {:ok, _} = Page.navigate(p1, fixture)
      {:ok, _} = Page.navigate(p2, fixture)

      assert :ok = CDPEx.close_page(browser, p1)
      assert map_size(:sys.get_state(browser).sessions) == 1

      # p1 is detached; p2 still works on the shared connection.
      assert {:error, _} = Page.evaluate(p1, "1 + 1")
      assert {:ok, 4} = Page.evaluate(p2, "2 + 2")
    end

    test "an externally-closed session target is pruned from state.sessions", %{fixture: fixture} do
      {:ok, browser} = CDPEx.launch()
      on_exit(fn -> stop_quietly(browser) end)

      {:ok, p1} = CDPEx.new_page(browser, transport: :session)
      {:ok, p2} = CDPEx.new_page(browser, transport: :session)
      {:ok, _} = Page.navigate(p1, fixture)
      {:ok, _} = Page.navigate(p2, fixture)
      assert map_size(:sys.get_state(browser).sessions) == 2

      # Close p1's target OUT OF BAND — directly on the browser connection, NOT via
      # close_page. Chrome emits Target.detachedFromTarget; the Browser must act on
      # it to prune the dead session, or it leaks for the life of the browser.
      browser_conn = :sys.get_state(browser).browser_conn
      {:ok, _} = Connection.call(browser_conn, "Target.closeTarget", %{"targetId" => p1.target_id})

      assert eventually(fn -> map_size(:sys.get_state(browser).sessions) == 1 end)

      # The surviving session is unaffected.
      assert {:ok, 4} = Page.evaluate(p2, "2 + 2")
    end
  end

  describe "page operations" do
    setup do
      {:ok, browser} = CDPEx.launch()
      {:ok, page} = CDPEx.new_page(browser)
      on_exit(fn -> stop_quietly(browser) end)
      %{browser: browser, page: page}
    end

    test "navigate then html returns the rendered DOM", %{page: page, fixture: fixture} do
      assert {:ok, ^page} = Page.navigate(page, fixture)
      assert :ok = Page.wait_for_selector(page, "#greeting")
      assert {:ok, html} = Page.html(page)
      assert html =~ "Hello"
      assert html =~ "CDPEx Fixture" or html =~ "greeting"
    end

    test "navigate/3 with wait_until: :load resolves (race-free) on a fast page", %{
      page: page,
      fixture: fixture
    } do
      # :load fires fast on a local page — the case most exposed to the old
      # register-after-navigate race. Subscribing before navigate must catch it.
      assert {:ok, ^page} = Page.navigate(page, fixture, wait_until: :load)
      assert {:ok, "Hello"} = Page.text(page, "#greeting")
    end

    test "navigate/3 response: true reports the post-redirect 200 and final URL", %{
      page: page,
      fixture: fixture
    } do
      # /redirect 302s to "/", so the reported response must be the FINAL landing
      # (200 at the root URL), not the redirect hop — correlation is by loaderId.
      assert {:ok, ^page, %{status: 200, url: url}} =
               Page.navigate(page, fixture <> "redirect", response: true)

      assert url == fixture
      assert {:ok, "Hello"} = Page.text(page, "#greeting")
    end

    test "navigate/3 response: true surfaces a 404 (a clean signal vs a bare {:ok, page})", %{
      page: page,
      fixture: fixture
    } do
      # A 404 still loads (it has a body), so the default navigate/3 can't tell it
      # apart from a 200. response: true exposes the status.
      missing = fixture <> "missing"

      assert {:ok, ^page, %{status: 404, url: ^missing}} =
               Page.navigate(page, missing, response: true)
    end

    test "evaluate returns a JS value", %{page: page, fixture: fixture} do
      {:ok, _} = Page.navigate(page, fixture)
      assert {:ok, "CDPEx Fixture"} = Page.evaluate(page, "document.title")
      assert {:ok, 3} = Page.evaluate(page, "1 + 2")
    end

    test "evaluate surfaces a thrown JS exception as an error", %{page: page, fixture: fixture} do
      {:ok, _} = Page.navigate(page, fixture)

      assert {:error, {:evaluate_exception, _details}} =
               Page.evaluate(page, "throw new Error('boom')")
    end

    test "call_function applies JSON args and returns the result", %{page: page, fixture: fixture} do
      {:ok, _} = Page.navigate(page, fixture)
      assert {:ok, 5} = Page.call_function(page, "(a, b) => a + b", [2, 3])
      assert {:ok, "HELLO"} = Page.call_function(page, "(s) => s.toUpperCase()", ["hello"])
    end

    test "wait_for_selector resolves for present and times out for absent", %{
      page: page,
      fixture: fixture
    } do
      {:ok, _} = Page.navigate(page, fixture)
      assert :ok = Page.wait_for_selector(page, "#greeting", timeout: 2_000)
      assert {:error, :timeout} = Page.wait_for_selector(page, "#does-not-exist", timeout: 300)
    end

    test "wait_for_function resolves when truthy and times out otherwise", %{
      page: page,
      fixture: fixture
    } do
      {:ok, _} = Page.navigate(page, fixture)

      assert :ok =
               Page.wait_for_function(page, "document.title === 'CDPEx Fixture'", timeout: 2_000)

      assert {:error, :timeout} =
               Page.wait_for_function(page, "window.__never__ === 1", timeout: 300)
    end

    test "text returns element text, nil when absent", %{page: page, fixture: fixture} do
      {:ok, _} = Page.navigate(page, fixture)
      :ok = Page.wait_for_selector(page, "#greeting")
      assert {:ok, "Hello"} = Page.text(page, "#greeting")
      assert {:ok, nil} = Page.text(page, "#does-not-exist")
    end

    test "attribute returns an element attribute, nil when absent", %{
      page: page,
      fixture: fixture
    } do
      {:ok, _} = Page.navigate(page, fixture)
      :ok = Page.wait_for_selector(page, "#greeting")
      assert {:ok, "greeting"} = Page.attribute(page, "#greeting", "id")
      assert {:ok, nil} = Page.attribute(page, "#greeting", "data-nope")
    end

    test "visible? reflects element visibility", %{page: page, fixture: fixture} do
      {:ok, _} = Page.navigate(page, fixture)
      :ok = Page.wait_for_selector(page, "#greeting")
      assert {:ok, true} = Page.visible?(page, "#greeting")
      assert {:ok, false} = Page.visible?(page, "#does-not-exist")
    end

    test "wait_for_navigation: :none is immediate, a no-nav wait times out", %{
      page: page,
      fixture: fixture
    } do
      {:ok, _} = Page.navigate(page, fixture)
      assert :ok = Page.wait_for_navigation(page, wait_until: :none)
      assert {:error, :timeout} = Page.wait_for_navigation(page, wait_until: :load, timeout: 300)
    end

    test "wait_for_navigation resolves on a milestone from an out-of-band navigation", %{
      page: page,
      fixture: fixture
    } do
      {:ok, _} = Page.navigate(page, fixture)
      # Trigger a navigation WITHOUT navigate/3 (deferred so evaluate returns before
      # the reload tears down the context), then await its lifecycle milestone — the
      # subscribe-before-wait path. The ~50ms defer also lets wait_for_navigation
      # subscribe before `load` fires, exercising the race fix.
      {:ok, _} = Page.evaluate(page, "setTimeout(() => location.reload(), 50); true")
      assert :ok = Page.wait_for_navigation(page, wait_until: :load, timeout: 5_000)
    end

    test "click toggles observable DOM state", %{page: page, fixture: fixture} do
      {:ok, _} = Page.navigate(page, fixture)
      :ok = Page.wait_for_selector(page, "#btn")
      assert {:ok, "Hello"} = Page.evaluate(page, "document.getElementById('greeting').textContent")
      assert :ok = Page.click(page, "#btn")

      assert {:ok, "Clicked"} =
               Page.evaluate(page, "document.getElementById('greeting').textContent")
    end

    test "click reports a missing selector", %{page: page, fixture: fixture} do
      {:ok, _} = Page.navigate(page, fixture)
      assert {:error, {:selector_not_found, "#nope"}} = Page.click(page, "#nope")
    end

    test "wait_for_network_idle settles after a click triggers a fetch", %{
      page: page,
      fixture: fixture
    } do
      {:ok, _} = Page.navigate(page, fixture)
      :ok = Page.wait_for_selector(page, "#fetch-btn")

      # Idleness is measured from the call onward, so arm it (in a task) and let it
      # subscribe BEFORE the click kicks off the fetch.
      waiter =
        Task.async(fn -> Page.wait_for_network_idle(page, idle_time: 300, timeout: 5_000) end)

      Process.sleep(200)
      assert :ok = Page.click(page, "#fetch-btn")

      assert :ok = Task.await(waiter, 10_000)
      # The fetch resolved during the idle wait — its handler writes the body into #greeting.
      assert {:ok, "fetched-data"} = Page.text(page, "#greeting")
    end

    test "wait_for_response returns the matching fetch response", %{page: page, fixture: fixture} do
      {:ok, _} = Page.navigate(page, fixture)
      :ok = Page.wait_for_selector(page, "#fetch-btn")

      # Arm the waiter (it enables Network + registers) before triggering the fetch.
      waiter = Task.async(fn -> Page.wait_for_response(page, "/data", timeout: 5_000) end)
      Process.sleep(200)
      assert :ok = Page.click(page, "#fetch-btn")

      assert {:ok, %{"requestId" => req, "response" => %{"status" => 200, "url" => url}}} =
               Task.await(waiter, 10_000)

      assert url =~ "/data"
      assert {:ok, "fetched-data"} = read_body_eventually(page, req)
    end

    test "wait_for_network_idle settles even when the fetch redirects", %{
      page: page,
      fixture: fixture
    } do
      {:ok, _} = Page.navigate(page, fixture)
      :ok = Page.wait_for_selector(page, "#redirect-fetch-btn")

      waiter =
        Task.async(fn -> Page.wait_for_network_idle(page, idle_time: 300, timeout: 5_000) end)

      Process.sleep(200)
      assert :ok = Page.click(page, "#redirect-fetch-btn")

      # The fetch hits /redirect (302 → /). The redirect hop must not leave a phantom
      # in-flight request, or this hangs to the timeout — regression guard for the
      # requestWillBeSent-per-hop overcount.
      assert :ok = Task.await(waiter, 10_000)
    end

    test "screenshot returns PNG bytes and can write a file", %{page: page, fixture: fixture} do
      {:ok, _} = Page.navigate(page, fixture)
      :ok = Page.wait_for_selector(page, "#greeting")

      assert {:ok, bytes} = Page.screenshot(page)
      # PNG magic number.
      assert <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, _rest::binary>> = bytes

      path = Path.join(System.tmp_dir!(), "cdp_ex_shot_#{System.unique_integer([:positive])}.png")
      assert {:ok, ^path} = Page.screenshot(page, path: path)
      assert File.exists?(path)
      File.rm(path)
    end

    test "cookies round-trip: set, read, clear", %{page: page, fixture: fixture} do
      {:ok, _} = Page.navigate(page, fixture)
      assert :ok = Page.set_cookies(page, [%{"name" => "cdpex", "value" => "42", "url" => fixture}])

      assert {:ok, cookies} = Page.cookies(page)
      assert Enum.any?(cookies, &(&1["name"] == "cdpex" and &1["value"] == "42"))

      assert :ok = Page.clear_cookies(page)
      assert {:ok, after_clear} = Page.cookies(page)
      refute Enum.any?(after_clear, &(&1["name"] == "cdpex"))
    end

    test "set_user_agent overrides navigator.userAgent", %{page: page, fixture: fixture} do
      assert :ok = Page.set_user_agent(page, "CDPExUA/1.0")
      {:ok, _} = Page.navigate(page, fixture)
      assert {:ok, "CDPExUA/1.0"} = Page.evaluate(page, "navigator.userAgent")
    end

    test "set_extra_headers are sent with the navigation request", %{page: page, fixture: fixture} do
      assert :ok = Page.set_extra_headers(page, %{"X-CDPEx-Test" => "hello"})
      {:ok, _} = Page.navigate(page, fixture)
      :ok = Page.wait_for_selector(page, "#echo-header")
      assert {:ok, "hello"} = Page.text(page, "#echo-header")
    end

    test "set_viewport changes the reported viewport size", %{page: page, fixture: fixture} do
      {:ok, _} = Page.navigate(page, fixture)
      assert :ok = Page.set_viewport(page, 800, 600)
      assert {:ok, 800} = Page.evaluate(page, "window.innerWidth")
      assert {:ok, 600} = Page.evaluate(page, "window.innerHeight")
    end

    test "pdf returns PDF bytes and can write a file", %{page: page, fixture: fixture} do
      {:ok, _} = Page.navigate(page, fixture)
      :ok = Page.wait_for_selector(page, "#greeting")

      assert {:ok, bytes} = Page.pdf(page)
      assert <<"%PDF-", _rest::binary>> = bytes

      path = Path.join(System.tmp_dir!(), "cdp_ex_doc_#{System.unique_integer([:positive])}.pdf")
      assert {:ok, ^path} = Page.pdf(page, path: path)
      assert File.exists?(path)
      File.rm(path)
    end
  end

  describe "network observation" do
    test "observe_network streams request/response events and response_body fetches the body", %{
      fixture: fixture
    } do
      {:ok, browser} = CDPEx.launch()
      {:ok, page} = CDPEx.new_page(browser)
      on_exit(fn -> stop_quietly(browser) end)

      assert :ok = Page.observe_network(page)
      {:ok, _} = Page.navigate(page, fixture)

      conn = page.conn

      assert_receive {:cdp_event, ^conn, "Network.requestWillBeSent",
                      %{"request" => %{"url" => req_url}}, _},
                     5_000

      assert req_url =~ "127.0.0.1"

      # Match the DOCUMENT response specifically (not whichever lands first), so
      # request_id points at the page itself — deterministic regardless of favicon
      # or other sub-resource probes.
      assert_receive {:cdp_event, ^conn, "Network.responseReceived",
                      %{"requestId" => request_id, "type" => "Document"}, _},
                     5_000

      assert {:ok, body} = Page.response_body(page, request_id)
      assert body =~ "Hello"

      # Stopping must actually halt delivery. stop_observing_network/2 is a
      # synchronous GenServer.call, so once it returns no new events are delivered —
      # flush AFTER the stop (not before), or a late in-flight event from the first
      # navigation could land post-flush and trip refute_receive.
      assert :ok = Page.stop_observing_network(page)
      flush_cdp_events()
      {:ok, _} = Page.navigate(page, fixture <> "?after-stop")
      refute_receive {:cdp_event, ^conn, "Network.requestWillBeSent", _, _}, 1_000
    end
  end

  describe "authentication" do
    test "authenticate answers an HTTP Basic challenge so a gated page loads", %{fixture: fixture} do
      auth_url = fixture <> "basic-auth"
      {:ok, browser} = CDPEx.launch()
      on_exit(fn -> stop_quietly(browser) end)

      # Without credentials the navigation is rejected outright — Chrome can't
      # answer the 401 challenge (net::ERR_INVALID_AUTH_CREDENTIALS).
      {:ok, blocked} = CDPEx.new_page(browser)
      assert {:error, {:navigate, _}} = Page.navigate(blocked, auth_url)

      # Armed with authenticate/4, the challenge is answered and the page loads —
      # which also proves the paused requests were auto-continued.
      {:ok, page} = CDPEx.new_page(browser)
      assert :ok = Page.authenticate(page, "cdpex", "secret")
      {:ok, _} = Page.navigate(page, auth_url)
      assert {:ok, "Hello"} = Page.text(page, "#greeting")
    end

    test "rejects a :session page rather than leak its handler" do
      {:ok, browser} = CDPEx.launch()
      on_exit(fn -> stop_quietly(browser) end)

      {:ok, session_page} = CDPEx.new_page(browser, transport: :session)

      assert {:error, {:unsupported_transport, :session}} =
               Page.authenticate(session_page, "cdpex", "secret")
    end

    test "the Fetch handler self-stops when the page's connection goes down" do
      {:ok, browser} = CDPEx.launch()
      on_exit(fn -> stop_quietly(browser) end)

      before = fetch_handlers()
      {:ok, page} = CDPEx.new_page(browser)
      assert :ok = Page.authenticate(page, "cdpex", "secret")

      assert [handler] = fetch_handlers() -- before
      ref = Process.monitor(handler)

      # Closing the dedicated page stops its connection; the handler monitors that
      # connection and must stop with it — no lingering GenServer, no armed Fetch.
      :ok = CDPEx.close_page(browser, page)
      assert_receive {:DOWN, ^ref, :process, ^handler, _reason}, 5_000
    end

    test "refuses to authenticate a page belonging to another browser" do
      {:ok, browser_a} = CDPEx.launch()
      {:ok, browser_b} = CDPEx.launch()
      on_exit(fn -> stop_quietly(browser_a) end)
      on_exit(fn -> stop_quietly(browser_b) end)

      {:ok, page_b} = CDPEx.new_page(browser_b)

      # Arming B's page through A must refuse (mirrors close_page) rather than link a
      # handler to a connection A doesn't own.
      assert {:error, :unknown_page} =
               Browser.authenticate(browser_a, page_b, username: "u", password: "p")

      # B's page is unharmed and still authenticates on its own browser.
      assert :ok = Page.authenticate(page_b, "cdpex", "secret")
    end

    test "refuses a second authenticate on an already-armed page" do
      {:ok, browser} = CDPEx.launch()
      on_exit(fn -> stop_quietly(browser) end)

      {:ok, page} = CDPEx.new_page(browser)
      assert :ok = Page.authenticate(page, "cdpex", "secret")
      assert {:error, :already_authenticated} = Page.authenticate(page, "cdpex", "secret")
    end
  end

  describe "proxy" do
    # The proxy is unreachable, but we never navigate — the auto-arm only enables Fetch
    # locally, and target/session creation goes over the debug socket, not through the
    # proxy. So these exercise the launch wiring without needing a real proxy server.
    @creds_proxy "http://user:pass@127.0.0.1:9"

    test "launch(proxy: creds) auto-arms a dedicated page (no manual authenticate/4)" do
      {:ok, browser} = CDPEx.launch(proxy: @creds_proxy)
      on_exit(fn -> stop_quietly(browser) end)

      assert {:ok, _page} = CDPEx.new_page(browser)
    end

    test "an auto-armed page rejects a second authenticate/4 (proxy occupies the Fetch slot)" do
      {:ok, browser} = CDPEx.launch(proxy: @creds_proxy)
      on_exit(fn -> stop_quietly(browser) end)

      {:ok, page} = CDPEx.new_page(browser)
      assert {:error, :already_authenticated} = Page.authenticate(page, "user", "pass")
    end

    test "an auto-armed page rejects request interception (Fetch mutual exclusion)" do
      {:ok, browser} = CDPEx.launch(proxy: @creds_proxy)
      on_exit(fn -> stop_quietly(browser) end)

      {:ok, page} = CDPEx.new_page(browser)
      assert {:error, {:conflict, :authenticated}} = Page.enable_request_interception(page)
    end

    test "launch(proxy: creds) rejects a :session page" do
      {:ok, browser} = CDPEx.launch(proxy: @creds_proxy)
      on_exit(fn -> stop_quietly(browser) end)

      assert {:error, {:unsupported_transport, :session}} =
               CDPEx.new_page(browser, transport: :session)
    end

    test "launch(proxy: url) without creds sets the flag only — any transport works" do
      {:ok, browser} = CDPEx.launch(proxy: "http://127.0.0.1:9")
      on_exit(fn -> stop_quietly(browser) end)

      assert {:ok, _page} = CDPEx.new_page(browser, transport: :session)
    end

    # The above use an unreachable proxy and never navigate. These two drive the full
    # round-trip against a real authenticating proxy: the auto-armed handler answers a
    # 407 (source: Proxy) with the launch credentials so traffic flows. The target host
    # is non-resolvable on purpose — a load can only happen THROUGH the proxy.
    test "auto-auth answers a proxy 407 so a navigation succeeds through the proxy" do
      {:ok, %{port: proxy_port}} = ProxyAuthServer.start(username: "puser", password: "ppass")
      {:ok, browser} = CDPEx.launch(proxy: "http://puser:ppass@127.0.0.1:#{proxy_port}")
      on_exit(fn -> stop_quietly(browser) end)

      {:ok, page} = CDPEx.new_page(browser)
      assert {:ok, _} = Page.navigate(page, "http://proxied.test/")
      assert {:ok, "Proxied"} = Page.text(page, "#greeting")
    end

    test "without credentials a proxy 407 blocks the navigation (the proxy enforces auth)" do
      # Same proxy, but launched with a credential-less URL: no Fetch handler is armed,
      # so Chrome can't answer the 407 and the navigation fails — which also proves the
      # positive test above isn't a no-op (the proxy genuinely challenges). `wait_until:
      # :none` pins the assertion to Page.navigate's synchronous errorText (net::ERR_*) for
      # the blocked load, rather than the default readiness wait (whose timeout navigate/3
      # reports as a best-effort {:ok, _}).
      {:ok, %{port: proxy_port}} = ProxyAuthServer.start(username: "puser", password: "ppass")
      {:ok, browser} = CDPEx.launch(proxy: "http://127.0.0.1:#{proxy_port}")
      on_exit(fn -> stop_quietly(browser) end)

      {:ok, page} = CDPEx.new_page(browser)

      assert {:error, {:navigate, _}} =
               Page.navigate(page, "http://proxied.test/", wait_until: :none)
    end
  end

  describe "request interception" do
    test "fulfill_request serves a synthetic response for an intercepted navigation", %{
      fixture: fixture
    } do
      {:ok, browser} = CDPEx.launch()
      {:ok, page} = CDPEx.new_page(browser)
      on_exit(fn -> stop_quietly(browser) end)

      assert :ok = Page.enable_request_interception(page)
      conn = page.conn

      # The document request is paused, so navigate blocks — drive it from a task and
      # fulfill the pause with a synthetic body.
      nav = Task.async(fn -> Page.navigate(page, fixture, wait_until: :load) end)

      assert_receive {:cdp_event, ^conn, "Fetch.requestPaused", %{"requestId" => req_id}, _}, 5_000

      assert :ok =
               Page.fulfill_request(page, req_id,
                 status: 200,
                 headers: %{"Content-Type" => "text/html"},
                 body: ~s(<h1 id="x">intercepted</h1>)
               )

      assert {:ok, _} = Task.await(nav, 10_000)
      assert {:ok, "intercepted"} = Page.text(page, "#x")

      assert :ok = Page.disable_request_interception(page)
    end

    test "continue_request lets an intercepted navigation reach the real server", %{
      fixture: fixture
    } do
      {:ok, browser} = CDPEx.launch()
      {:ok, page} = CDPEx.new_page(browser)
      on_exit(fn -> stop_quietly(browser) end)

      assert :ok = Page.enable_request_interception(page)
      conn = page.conn

      nav = Task.async(fn -> Page.navigate(page, fixture, wait_until: :load) end)

      assert_receive {:cdp_event, ^conn, "Fetch.requestPaused", %{"requestId" => req_id}, _}, 5_000
      assert :ok = Page.continue_request(page, req_id)

      assert {:ok, _} = Task.await(nav, 10_000)
      # Continued (not fulfilled), so the page shows the REAL fixture content.
      assert {:ok, "Hello"} = Page.text(page, "#greeting")

      assert :ok = Page.disable_request_interception(page)
    end

    test "fail_request aborts an intercepted request", %{fixture: fixture} do
      {:ok, browser} = CDPEx.launch()
      {:ok, page} = CDPEx.new_page(browser)
      on_exit(fn -> stop_quietly(browser) end)

      assert :ok = Page.enable_request_interception(page)
      conn = page.conn

      # The document request is paused; failing it aborts the navigation, which the
      # Page.navigate command then reports as an error.
      nav = Task.async(fn -> Page.navigate(page, fixture, wait_until: :none) end)

      assert_receive {:cdp_event, ^conn, "Fetch.requestPaused", %{"requestId" => req_id}, _}, 5_000
      assert :ok = Page.fail_request(page, req_id, reason: :aborted)

      assert {:error, {:navigate, _}} = Task.await(nav, 10_000)

      assert :ok = Page.disable_request_interception(page)
    end

    test "auto-disables Fetch when the interception owner process dies (anti-brick)", %{
      fixture: fixture
    } do
      {:ok, browser} = CDPEx.launch()
      {:ok, page} = CDPEx.new_page(browser)
      on_exit(fn -> stop_quietly(browser) end)

      test = self()

      # Enable interception from a separate process, then kill it WITHOUT disabling.
      owner =
        spawn(fn ->
          send(test, {:enabled, Page.enable_request_interception(page)})
          Process.sleep(:infinity)
        end)

      assert_receive {:enabled, :ok}, 5_000

      ref = Process.monitor(owner)
      Process.exit(owner, :kill)
      assert_receive {:DOWN, ^ref, :process, ^owner, _}, 5_000

      # The browser monitors the owner and Fetch.disables the page (off-process) when
      # it dies. Poll a fresh navigation until it actually renders: while Fetch is
      # still enabled the document stays paused and a short-timeout navigate returns
      # best-effort without loading, so the selector text stays absent; once the
      # async disable lands the page loads. Pre-fix it would never recover.
      assert eventually(fn ->
               Page.navigate(page, fixture, wait_until: :load, timeout: 1_000)
               match?({:ok, "Hello"}, Page.text(page, "#greeting"))
             end)
    end

    test "interception and authenticate are mutually exclusive per page" do
      {:ok, browser} = CDPEx.launch()
      on_exit(fn -> stop_quietly(browser) end)

      # Authenticate first → interception is refused.
      {:ok, p1} = CDPEx.new_page(browser)
      assert :ok = Page.authenticate(p1, "cdpex", "secret")
      assert {:error, {:conflict, :authenticated}} = Page.enable_request_interception(p1)

      # Intercept first → authenticate is refused (the reverse direction).
      {:ok, p2} = CDPEx.new_page(browser)
      assert :ok = Page.enable_request_interception(p2)
      assert {:error, {:conflict, :intercepting}} = Page.authenticate(p2, "cdpex", "secret")
      assert :ok = Page.disable_request_interception(p2)
    end
  end

  describe "tracer bullet" do
    test "with_page reproduces the spike's fetch end-to-end", %{fixture: fixture} do
      # The whole point: one call launches Chrome, opens a page, runs the fun,
      # and tears everything down — returning the page HTML, through the
      # supervised GenServer stack rather than the spike's blocking process.
      result =
        CDPEx.with_page([], fn page ->
          {:ok, _} = Page.navigate(page, fixture)
          :ok = Page.wait_for_selector(page, "#greeting")
          Page.html(page)
        end)

      assert {:ok, html} = result
      assert html =~ "Hello"
    end

    test "with_page cleans up the browser even when the fun raises" do
      assert_raise RuntimeError, fn ->
        CDPEx.with_page([], fn _page -> raise "boom" end)
      end

      # No orphaned Chrome from the raising run is asserted at the suite level
      # (see the no-orphan check in the test command); here we just confirm the
      # raise propagates rather than being swallowed.
    end

    test "with_page contains a browser crash without killing a non-trapping caller" do
      parent = self()

      # A caller that does NOT trap exits. Pre-fix, with_page linked the throwaway
      # browser to it, so killing Chrome would take this process down with the
      # browser's exit. The fix traps inside with_page, so the caller instead gets
      # {:error, _} and exits :normal.
      {caller, ref} =
        spawn_monitor(fn ->
          result =
            CDPEx.with_page([], fn page ->
              %{chrome: %{os_pid: os_pid}} = :sys.get_state(page.browser)
              System.cmd("kill", ["-9", to_string(os_pid)])
              Page.evaluate(page, "1 + 1")
            end)

          send(parent, {:with_page_result, result})
        end)

      assert_receive {:with_page_result, {:error, _}}, 30_000
      assert_receive {:DOWN, ^ref, :process, ^caller, :normal}, 5_000
    end
  end

  describe "pool" do
    test "with_page reuses a warm pooled browser across calls", %{fixture: fixture} do
      {:ok, pool} = Pool.start_link(size: 1)
      on_exit(fn -> stop_pool_quietly(pool) end)

      used = fn ->
        Pool.with_page(pool, fn page ->
          {:ok, _} = Page.navigate(page, fixture)
          page.browser
        end)
      end

      b1 = used.()
      b2 = used.()
      assert is_pid(b1)
      assert b1 == b2, "expected the pooled browser to be reused across with_page calls"
      assert :sys.get_state(pool).count == 1
    end

    test "with_page runs on a pooled browser and returns the fun's value", %{fixture: fixture} do
      {:ok, pool} = Pool.start_link(size: 1)
      on_exit(fn -> stop_pool_quietly(pool) end)

      result =
        Pool.with_page(pool, fn page ->
          {:ok, _} = Page.navigate(page, fixture)
          Page.text(page, "#greeting")
        end)

      assert {:ok, "Hello"} = result
    end

    test "a pooled browser self-reaps when the pool is hard-killed (#22)" do
      # The pool adopts a task-launched browser with owner: pool, so the browser's
      # owner-death self-reap (defense-in-depth for a skipped terminate/2) still fires when
      # the pool is :brutal_killed — rather than orphaning Chrome. Trap exits so the pool's
      # death (it is start_linked to us) doesn't take the test down.
      Process.flag(:trap_exit, true)

      {:ok, pool} = Pool.start_link(size: 1)
      {:ok, browser} = Pool.checkout(pool)
      bref = Process.monitor(browser)

      # The browser's self-reap logs an (expected) termination report — capture it.
      capture_log(fn ->
        Process.exit(pool, :kill)
        assert_receive {:DOWN, ^bref, :process, ^browser, _reason}, 10_000
      end)
    end
  end

  describe "telemetry" do
    test "CDPEx.launch/1 emits a [:cdp_ex, :launch] span with a positive duration" do
      attach_telemetry([[:cdp_ex, :launch, :stop]])

      {:ok, browser} = CDPEx.launch()
      on_exit(fn -> stop_quietly(browser) end)

      assert_receive {:telemetry, [:cdp_ex, :launch, :stop], %{duration: duration}, _meta}, 15_000
      assert duration > 0
    end

    test "opening and closing a page emits [:cdp_ex, :page, :start] then :stop, no error" do
      attach_telemetry([[:cdp_ex, :page, :start], [:cdp_ex, :page, :stop], [:cdp_ex, :error]])

      {:ok, browser} = CDPEx.launch()
      on_exit(fn -> stop_quietly(browser) end)

      {:ok, page} = CDPEx.new_page(browser)

      assert_receive {:telemetry, [:cdp_ex, :page, :start], %{system_time: _},
                      %{target_id: tid, transport: :dedicated}},
                     5_000

      assert tid == page.target_id

      :ok = CDPEx.close_page(browser, page)
      assert_receive {:telemetry, [:cdp_ex, :page, :stop], _, %{transport: :dedicated}}, 5_000

      # A clean close is not a fault — no [:cdp_ex, :error].
      refute_received {:telemetry, [:cdp_ex, :error], _, _}
    end

    test "a :session page open/close emits :start/:stop with transport: :session", %{
      fixture: fixture
    } do
      attach_telemetry([[:cdp_ex, :page, :start], [:cdp_ex, :page, :stop]])

      {:ok, browser} = CDPEx.launch()
      on_exit(fn -> stop_quietly(browser) end)

      {:ok, page} = CDPEx.new_page(browser, transport: :session)
      assert_receive {:telemetry, [:cdp_ex, :page, :start], _, %{transport: :session}}, 5_000

      {:ok, _} = Page.navigate(page, fixture)
      :ok = CDPEx.close_page(browser, page)
      assert_receive {:telemetry, [:cdp_ex, :page, :stop], _, %{transport: :session}}, 5_000
    end

    test "a page that dies with Chrome emits no [:cdp_ex, :page, :stop]" do
      attach_telemetry([[:cdp_ex, :page, :stop]])

      {:ok, browser} = CDPEx.launch()
      {:ok, _page} = CDPEx.new_page(browser)

      %{chrome: %{os_pid: os_pid}} = :sys.get_state(browser)
      System.cmd("kill", ["-9", to_string(os_pid)])

      # :stop fires only on an explicit close_page/2 — a page dying with Chrome does not
      # emit it (consumers learn of the loss via [:cdp_ex, :error] instead).
      refute_receive {:telemetry, [:cdp_ex, :page, :stop], _, _}, 2_000
    end

    test "killing Chrome emits a [:cdp_ex, :error] fault event" do
      attach_telemetry([[:cdp_ex, :error]])

      {:ok, browser} = CDPEx.launch()

      %{chrome: %{os_pid: os_pid}} = :sys.get_state(browser)
      System.cmd("kill", ["-9", to_string(os_pid)])

      # Chrome's port exit and the browser-connection drop race; whichever the Browser
      # processes first stops it, so assert a genuine fault event fires (any of the three
      # contexts) rather than pinning the order.
      assert_receive {:telemetry, [:cdp_ex, :error], %{system_time: _}, %{context: context}}, 10_000
      assert context in [:chrome_exited, :browser_connection_down, :ws_closed]
    end
  end

  # Attach a telemetry handler forwarding each event to the test process; detach on exit.
  # A named (module) handler avoids :telemetry's local/anonymous-handler warning; the
  # config (4th arg) carries the test pid.
  defp attach_telemetry(events) do
    id = "integration-telemetry-#{System.unique_integer([:positive])}"
    :telemetry.attach_many(id, events, &__MODULE__.forward/4, self())
    on_exit(fn -> :telemetry.detach(id) end)
  end

  @doc false
  def forward(event, measurements, metadata, test_pid) do
    send(test_pid, {:telemetry, event, measurements, metadata})
  end

  # Teardown helper. The browser is linked to (and watches) the test process, so
  # by the time on_exit runs it may already be stopping on its own — racing this
  # call. Tolerate an exit from the stop so a teardown race never fails a test
  # whose body already passed.
  # Drain any buffered {:cdp_event, ...} messages from the mailbox.
  defp flush_cdp_events do
    receive do
      {:cdp_event, _, _, _, _} -> flush_cdp_events()
    after
      0 -> :ok
    end
  end

  # The Fetch handlers currently alive (matched by their initial call), so a test
  # can isolate the one a given authenticate/4 started.
  defp fetch_handlers do
    for pid <- Process.list(),
        {:dictionary, dict} <- [Process.info(pid, :dictionary)],
        Keyword.get(dict, :"$initial_call") == {CDPEx.Fetch, :init, 1},
        do: pid
  end

  defp stop_quietly(browser) do
    if Process.alive?(browser), do: CDPEx.stop(browser)
  catch
    :exit, _ -> :ok
  end

  defp stop_pool_quietly(pool) do
    if Process.alive?(pool), do: Pool.stop(pool)
  catch
    :exit, _ -> :ok
  end

  # Poll until `fun` is true or the deadline passes — for event-driven state (e.g.
  # a CDP event pruning a map) that settles asynchronously after the triggering call.
  defp eventually(fun, retries \\ 50) do
    cond do
      fun.() ->
        true

      retries == 0 ->
        false

      true ->
        Process.sleep(20)
        eventually(fun, retries - 1)
    end
  end

  # wait_for_response/3 resolves on Network.responseReceived (headers/status arrived),
  # but Chrome only guarantees the body via Network.getResponseBody after
  # loadingFinished. In that window getResponseBody returns -32000 "No data found for
  # resource with given identifier" — a transient race, widened under CI load. Retry only
  # that specific error so the assertion still surfaces any genuine failure verbatim.
  defp read_body_eventually(page, req, retries \\ 20)

  defp read_body_eventually(page, req, 0), do: Page.response_body(page, req)

  defp read_body_eventually(page, req, retries) do
    case Page.response_body(page, req) do
      {:error, {:cdp_error, "Network.getResponseBody", %{"code" => -32_000}}} ->
        Process.sleep(50)
        read_body_eventually(page, req, retries - 1)

      other ->
        other
    end
  end
end
