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

    # Reading a label back needs :proc_lib.get_label/1 (OTP 27). The integration
    # lane pins a newer OTP, but a contributor on 26 should skip rather than fail.
    if Code.ensure_loaded?(:proc_lib) and function_exported?(:proc_lib, :get_label, 1) do
      test "the browser is labelled with Chrome's OS pid and its page conn with the target" do
        {:ok, browser} = CDPEx.launch()
        on_exit(fn -> stop_quietly(browser) end)

        assert {:cdp_browser, os_pid} = :proc_lib.get_label(browser)
        assert is_integer(os_pid)
        # The label names a process the OS agrees exists — that is the whole point
        # of labelling the browser by OS pid rather than by an internal counter.
        assert {_out, 0} = System.cmd("ps", ["-p", Integer.to_string(os_pid)])

        assert {:ok, %Page{} = page} = CDPEx.new_page(browser)
        assert {:cdp_connection, "/devtools/page/" <> target} = :proc_lib.get_label(page.conn)
        assert target == page.target_id
      end
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

  describe "connect" do
    test "connects via http discovery, drives a page, and leaves Chrome alive on stop", %{
      fixture: fixture
    } do
      # A: a normally-launched browser that OWNS the Chrome process.
      {:ok, a} = CDPEx.launch()
      on_exit(fn -> stop_quietly(a) end)
      %{host: host, port: port} = :sys.get_state(a)

      # B: connect to the SAME Chrome via its http endpoint (/json/version discovery).
      {:ok, b} = CDPEx.connect("http://#{host}:#{port}")

      {:ok, page} = CDPEx.new_page(b, transport: :session)
      b_target = page.target_id
      {:ok, _} = Page.navigate(page, fixture)
      assert {:ok, "Hello"} = Page.text(page, "#greeting")

      # A tab opened directly on A (a "pre-existing" tab from B's perspective) that
      # B's teardown must leave untouched.
      {:ok, a_pre} = CDPEx.new_page(a, transport: :session)
      a_pre_target = a_pre.target_id

      # Dedicated transport is not supported over a connected browser yet.
      assert {:error, {:unsupported_transport, :dedicated}} =
               CDPEx.new_page(b, transport: :dedicated)

      # Stopping B must NOT kill the Chrome A owns...
      assert :ok = CDPEx.stop(b)

      # ...and it must close only the tabs B opened, leaving pre-existing ones alone.
      # (Query the live targets through A's own browser connection.) stop(b) returns
      # once B's transport is torn down, but the remote can take a beat to drop the
      # closed tab from Target.getTargets — poll rather than snapshot once, or this
      # races on a loaded runner.
      %{browser_conn: a_conn} = :sys.get_state(a)

      live_targets = fn ->
        {:ok, %{"targetInfos" => infos}} = Connection.call(a_conn, "Target.getTargets", %{})
        Enum.map(infos, & &1["targetId"])
      end

      # Poll until B's tab disappears, then re-snapshot once and assert against that
      # snapshot — a genuine stop/1 regression (tab never closes) then reports what
      # is still live instead of a bare "got false" timeout.
      eventually(fn -> b_target not in live_targets.() end)
      final_live = live_targets.()

      refute b_target in final_live,
             "B's session tab should have been closed by stop(b); still live: #{inspect(final_live)}"

      assert a_pre_target in final_live,
             "a pre-existing tab on A must survive B's teardown"

      # A still works afterward.
      assert {:ok, a_page} = CDPEx.new_page(a, transport: :session)
      {:ok, _} = Page.navigate(a_page, fixture)
      assert {:ok, "Hello"} = Page.text(a_page, "#greeting")
    end

    test "with_page(connect:) runs against a running Chrome and leaves it alive", %{
      fixture: fixture
    } do
      {:ok, a} = CDPEx.launch()
      on_exit(fn -> stop_quietly(a) end)
      %{host: host, port: port} = :sys.get_state(a)

      result =
        CDPEx.with_page([connect: "http://#{host}:#{port}"], fn page ->
          {:ok, _} = Page.navigate(page, fixture)
          Page.text(page, "#greeting")
        end)

      assert {:ok, "Hello"} = result
      assert {:ok, _} = CDPEx.new_page(a, transport: :session)
    end
  end

  describe "session transport" do
    test "closing a session page fails a call blocked on it, and later calls, at once (#121)", %{
      fixture: fixture
    } do
      {:ok, browser} = CDPEx.launch()
      on_exit(fn -> stop_quietly(browser) end)
      {:ok, page} = CDPEx.new_page(browser, transport: :session)
      {:ok, _} = Page.navigate(page, fixture)
      sid = page.session_id

      blocked =
        Task.async(fn ->
          Page.evaluate(page, "new Promise(() => {})", await_promise: true, timeout: 15_000)
        end)

      assert eventually(fn -> map_size(:sys.get_state(page.conn).pending) > 0 end, 100)

      {elapsed_us, :ok} = :timer.tc(fn -> CDPEx.close_page(browser, page) end)
      assert {:error, {:session_closed, ^sid}} = Task.await(blocked, 2_000)
      assert elapsed_us < 2_000_000

      {elapsed_us, result} = :timer.tc(fn -> Page.evaluate(page, "1") end)
      assert result == {:error, {:session_closed, sid}}
      assert elapsed_us < 1_000_000
    end

    test "closing a session page ends a wait_for_selector on it promptly (#121)", %{
      fixture: fixture
    } do
      {:ok, browser} = CDPEx.launch()
      on_exit(fn -> stop_quietly(browser) end)
      {:ok, page} = CDPEx.new_page(browser, transport: :session)
      {:ok, _} = Page.navigate(page, fixture)
      sid = page.session_id

      waiting =
        Task.async(fn ->
          :timer.tc(fn -> Page.wait_for_selector(page, "#never-appears", timeout: 8_000) end)
        end)

      Process.sleep(300)
      :ok = CDPEx.close_page(browser, page)

      assert {elapsed_us, {:error, {:session_closed, ^sid}}} = Task.await(waiting, 5_000)
      assert elapsed_us < 2_000_000
    end

    test "closing a session page ends a navigation or network-idle wait on it promptly (#121)", %{
      fixture: fixture
    } do
      {:ok, browser} = CDPEx.launch()
      on_exit(fn -> stop_quietly(browser) end)

      waits = [
        &Page.wait_for_navigation(&1, timeout: 8_000),
        &Page.wait_for_network_idle(&1, idle_time: 6_000, timeout: 8_000)
      ]

      for wait <- waits do
        {:ok, page} = CDPEx.new_page(browser, transport: :session)
        {:ok, _} = Page.navigate(page, fixture)
        sid = page.session_id

        waiting = Task.async(fn -> :timer.tc(fn -> wait.(page) end) end)

        assert eventually(fn -> detach_watched?(page) end, 100),
               "the wait never subscribed to its session's detach"

        :ok = CDPEx.close_page(browser, page)

        assert {elapsed_us, {:error, {:session_closed, ^sid}}} = Task.await(waiting, 5_000)
        assert elapsed_us < 2_000_000
      end

      # A session already gone when the wait starts: no detach event is coming.
      {:ok, page} = CDPEx.new_page(browser, transport: :session)
      :ok = CDPEx.close_page(browser, page)

      for wait <- waits do
        {elapsed_us, result} = :timer.tc(fn -> wait.(page) end)
        assert result == {:error, {:session_closed, page.session_id}}
        assert elapsed_us < 1_000_000
      end
    end

    test "a with_page deadline on a browser pid's session page returns near the deadline (#121)",
         %{fixture: fixture} do
      {:ok, browser} = CDPEx.launch()
      on_exit(fn -> stop_quietly(browser) end)

      {elapsed_us, result} =
        :timer.tc(fn ->
          CDPEx.with_page(
            browser,
            fn page ->
              {:ok, _} = Page.navigate(page, fixture)
              Process.put(:waiting, true)
              Page.wait_for_selector(page, "#never-appears", timeout: 8_000)
            end,
            transport: :session,
            deadline: 3_000
          )
        end)

      assert Process.get(:waiting), "fun didn't reach its wait within the deadline"
      assert result == {:error, :deadline_exceeded}
      # Before #121 the in-flight evaluate waited out its 15s call timeout.
      assert elapsed_us < 4_500_000
      assert :sys.get_state(browser).sessions == %{}
    end

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

    test "observe_network only delivers the observed page's own session events", %{fixture: fixture} do
      {:ok, browser} = CDPEx.launch()
      on_exit(fn -> stop_quietly(browser) end)

      {:ok, p1} = CDPEx.new_page(browser, transport: :session)
      {:ok, p2} = CDPEx.new_page(browser, transport: :session)

      # A separate observer enables Network on p2's session so p2 actually emits
      # events on the shared connection — events that must NOT reach p1's observer.
      parent = self()

      observer_b =
        spawn_link(fn ->
          :ok = Page.observe_network(p2)
          send(parent, :b_ready)
          receive do: (:stop -> :ok)
        end)

      assert_receive :b_ready, 5_000
      assert :ok = Page.observe_network(p1)

      # p2's navigation fires Network events on p2's session; scoped delivery means
      # this process (observing p1) must not receive any of them.
      {:ok, _} = Page.navigate(p2, fixture)
      refute_receive {:cdp_event, _, "Network.requestWillBeSent", _, _}, 800

      # p1's own navigation IS delivered here, tagged with p1's session id.
      {:ok, _} = Page.navigate(p1, fixture)
      assert_receive {:cdp_event, _, "Network.requestWillBeSent", _, sid}, 2_000
      assert sid == p1.session_id

      send(observer_b, :stop)
    end

    test "one process observing two session pages receives both pages' events", %{fixture: fixture} do
      {:ok, browser} = CDPEx.launch()
      on_exit(fn -> stop_quietly(browser) end)

      {:ok, p1} = CDPEx.new_page(browser, transport: :session)
      {:ok, p2} = CDPEx.new_page(browser, transport: :session)

      # The SAME process observes both pages on the shared connection. Subscriptions
      # must accumulate per session, not clobber — so this process receives events
      # tagged with BOTH session ids (the regression the filter-set model fixes).
      assert :ok = Page.observe_network(p1)
      assert :ok = Page.observe_network(p2)

      {:ok, _} = Page.navigate(p1, fixture)
      {:ok, _} = Page.navigate(p2, fixture)

      s1 = p1.session_id
      s2 = p2.session_id
      assert_receive {:cdp_event, _, "Network.requestWillBeSent", _, ^s1}, 3_000
      assert_receive {:cdp_event, _, "Network.requestWillBeSent", _, ^s2}, 3_000
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

    test "navigate/3 ends on a client-side redirect's successor document, not the deadline", %{
      page: page,
      fixture: fixture
    } do
      # /meta-refresh commits, then replaces itself with "/" under a NEW loaderId before
      # it ever goes network-quiet. The wait must end on the successor's milestone; the
      # reported response stays this navigation's own document (the 200 at /meta-refresh).
      start = fixture <> "meta-refresh"

      {elapsed_us, result} =
        :timer.tc(fn -> Page.navigate(page, start, response: true, timeout: 10_000) end)

      assert {:ok, ^page, %{status: 200, url: ^start}} = result
      assert elapsed_us < 5_000_000, "navigate stalled #{div(elapsed_us, 1000)}ms (deadline-bound)"
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

    test "evaluate's non-serializable outcomes match the documented shapes", %{
      page: page,
      fixture: fixture
    } do
      {:ok, _} = Page.navigate(page, fixture)

      # A DOM node or function is serialized lossily to an empty object under
      # returnByValue — NOT an error, and NOT the object itself.
      assert {:ok, %{}} = Page.evaluate(page, "document.body")
      assert {:ok, %{}} = Page.evaluate(page, "(function () { return 1; })")

      # An unserializable number (returned by Chrome as `unserializableValue`,
      # so no by-value `value` key) gets the dedicated recoverable tag, carrying
      # the raw string.
      assert {:error, {:unserializable_value, "10n"}} = Page.evaluate(page, "10n")
      assert {:error, {:unserializable_value, "NaN"}} = Page.evaluate(page, "NaN")
      assert {:error, {:unserializable_value, "Infinity"}} = Page.evaluate(page, "1 / 0")
      assert {:error, {:unserializable_value, "-0"}} = Page.evaluate(page, "-0")

      # call_function/3 delegates to evaluate/3, so it surfaces the same tag.
      assert {:error, {:unserializable_value, "NaN"}} = Page.call_function(page, "() => NaN", [])

      # A value Chrome can't serialize at all (self-referential / circular / a
      # Symbol) fails the Runtime.evaluate call itself.
      assert {:error, {:cdp_error, "Runtime.evaluate", _}} = Page.evaluate(page, "window")

      assert {:error, {:cdp_error, "Runtime.evaluate", _}} =
               Page.evaluate(page, "(function () { var o = {}; o.self = o; return o; })()")

      assert {:error, {:cdp_error, "Runtime.evaluate", _}} = Page.evaluate(page, "Symbol(\"x\")")
    end

    test "click/3 dispatches a trusted event by default", %{page: page, fixture: fixture} do
      {:ok, _} = Page.navigate(page, fixture)
      assert :ok = Page.click(page, "#trusted-btn")
      assert {:ok, "trusted"} = Page.text(page, "#greeting")
    end

    test "click/3 trusted: false uses a synthetic event", %{page: page, fixture: fixture} do
      {:ok, _} = Page.navigate(page, fixture)
      assert :ok = Page.click(page, "#trusted-btn", trusted: false)
      assert {:ok, "untrusted"} = Page.text(page, "#greeting")
    end

    test "click/3 returns :not_clickable for a zero-box element", %{page: page, fixture: fixture} do
      {:ok, _} = Page.navigate(page, fixture)
      assert {:error, {:not_clickable, "#hidden-btn"}} = Page.click(page, "#hidden-btn")
    end

    test "click/3 returns :selector_not_found for no match", %{page: page, fixture: fixture} do
      {:ok, _} = Page.navigate(page, fixture)
      assert {:error, {:selector_not_found, "#nope"}} = Page.click(page, "#nope")
    end

    test "click/3 :wait clicks an element that is injected after load", %{
      page: page,
      fixture: fixture
    } do
      {:ok, _} = Page.navigate(page, fixture <> "interact", wait_until: :load)
      assert {:error, {:selector_not_found, "#late-btn"}} = Page.click(page, "#late-btn")
      assert {:ok, true} = Page.evaluate(page, "armLate(300)")
      assert :ok = Page.click(page, "#late-btn", wait: 5_000)
      assert [%{"id" => "late-btn", "trusted" => true}] = clicks(page)
    end

    test "click/3 :wait gives up with the last error once the budget is spent", %{
      page: page,
      fixture: fixture
    } do
      {:ok, _} = Page.navigate(page, fixture <> "interact", wait_until: :load)
      {elapsed_us, result} = :timer.tc(fn -> Page.click(page, "#hidden-text-btn", wait: 400) end)
      assert result == {:error, {:not_clickable, "#hidden-text-btn"}}
      assert elapsed_us >= 400_000
    end

    test "click_text/3 clicks the innermost match, not its wrapper", %{
      page: page,
      fixture: fixture
    } do
      {:ok, _} = Page.navigate(page, fixture <> "interact", wait_until: :load)
      assert :ok = Page.click_text(page, "Load more")
      assert [%{"id" => "inner", "trusted" => true}] = clicks(page)
    end

    test "click_text/3 trusted: false clicks the same element synthetically", %{
      page: page,
      fixture: fixture
    } do
      {:ok, _} = Page.navigate(page, fixture <> "interact", wait_until: :load)
      assert :ok = Page.click_text(page, "Load more", trusted: false)
      assert [%{"id" => "inner", "trusted" => false}] = clicks(page)
    end

    test "click_text/3 skips a hidden duplicate for the visible match", %{
      page: page,
      fixture: fixture
    } do
      {:ok, _} = Page.navigate(page, fixture <> "interact", wait_until: :load)
      assert :ok = Page.click_text(page, "Open menu", wait: 5_000)
      assert :ok = Page.click_text(page, "Open menu", trusted: false)

      assert [
               %{"id" => "menu-visible", "trusted" => true},
               %{"id" => "menu-visible", "trusted" => false}
             ] =
               clicks(page)
    end

    test "click_text/3 climbs from a boxless innermost match to its clickable ancestor", %{
      page: page,
      fixture: fixture
    } do
      {:ok, _} = Page.navigate(page, fixture <> "interact", wait_until: :load)
      assert :ok = Page.click_text(page, "Close")
      assert :ok = Page.click_text(page, "Next")
      # A synthetic click targets the picked element itself: the button, not the <svg>.
      assert :ok = Page.click_text(page, "Close", trusted: false)

      assert [
               %{"id" => "icon-close", "trusted" => true},
               %{"id" => "next-link", "trusted" => true},
               %{"id" => "icon-close", "tag" => "button", "trusted" => false}
             ] = clicks(page)
    end

    test "click_text/3 trusted: false clicks a non-HTML match (SVG <text>) without throwing", %{
      page: page,
      fixture: fixture
    } do
      {:ok, _} = Page.navigate(page, fixture <> "interact", wait_until: :load)
      assert :ok = Page.click_text(page, "Zoom", trusted: false)
      assert [%{"id" => "svg-zoom", "tag" => "text", "trusted" => false}] = clicks(page)
    end

    test "click_text/3 matches with whitespace normalized", %{page: page, fixture: fixture} do
      {:ok, _} = Page.navigate(page, fixture <> "interact", wait_until: :load)
      assert :ok = Page.click_text(page, "  Show all\n events ")
      assert [%{"id" => "ws-link", "trusted" => true}] = clicks(page)
    end

    test "click_text/3 :selector restricts the candidates", %{page: page, fixture: fixture} do
      {:ok, _} = Page.navigate(page, fixture <> "interact", wait_until: :load)
      assert :ok = Page.click_text(page, "Subscribe")
      assert :ok = Page.click_text(page, "Subscribe", selector: "button, a")

      assert [%{"id" => "label-span"}, %{"id" => "subscribe-btn"}] = clicks(page)
    end

    test "click_text/3 errors", %{page: page, fixture: fixture} do
      {:ok, _} = Page.navigate(page, fixture <> "interact", wait_until: :load)
      assert {:error, {:text_not_found, "Nope"}} = Page.click_text(page, "Nope")
      # Exact after normalization: a substring of a label is not a match.
      assert {:error, {:text_not_found, "Load"}} = Page.click_text(page, "Load")
      assert {:error, {:not_clickable, "Invisible"}} = Page.click_text(page, "Invisible")

      assert {:error, {:evaluate_exception, _}} =
               Page.click_text(page, "Nope", selector: ":::", wait: 5_000)

      assert clicks(page) == []
    end

    test "click_text/3 :wait clicks text that appears after load", %{
      page: page,
      fixture: fixture
    } do
      {:ok, _} = Page.navigate(page, fixture <> "interact", wait_until: :load)
      assert {:error, {:text_not_found, "Arrived late"}} = Page.click_text(page, "Arrived late")
      assert {:ok, true} = Page.evaluate(page, "armLate(300)")
      assert :ok = Page.click_text(page, "Arrived late", wait: 5_000)
      assert [%{"id" => "late-btn", "trusted" => true}] = clicks(page)
    end

    test "scroll/3 moves the window to the bottom, a point, and the top", %{
      page: page,
      fixture: fixture
    } do
      {:ok, _} = Page.navigate(page, fixture <> "interact", wait_until: :load)
      assert {:ok, 0} = Page.evaluate(page, "window.scrollY")

      assert :ok = Page.scroll(page, :bottom)

      assert {:ok, true} =
               Page.evaluate(
                 page,
                 "window.scrollY > 0 && window.scrollY + window.innerHeight >= document.documentElement.scrollHeight - 1"
               )

      assert :ok = Page.scroll(page, {0, 1234})
      assert {:ok, 1234} = Page.evaluate(page, "window.scrollY")

      assert :ok = Page.scroll(page, :top)
      assert {:ok, 0} = Page.evaluate(page, "window.scrollY")
    end

    test "scroll/3 is instant under CSS smooth scrolling", %{page: page, fixture: fixture} do
      {:ok, _} = Page.navigate(page, fixture <> "interact?smooth", wait_until: :load)

      assert {:ok, "smooth"} =
               Page.evaluate(page, "getComputedStyle(document.documentElement).scrollBehavior")

      assert :ok = Page.scroll(page, {0, 1234})
      assert {:ok, 1234} = Page.evaluate(page, "window.scrollY")
    end

    test "type/4 enters text into a field and fires input events", %{page: page, fixture: fixture} do
      {:ok, _} = Page.navigate(page, fixture)
      assert :ok = Page.type(page, "#name", "Ada")
      assert {:ok, "Ada"} = Page.evaluate(page, "document.getElementById('name').value")
      # #typed is written by an `oninput` handler, so this proves a real input
      # event fired (a JS `.value =` assignment would not trigger it).
      assert {:ok, "Ada"} = Page.text(page, "#typed")
    end

    test "type/4 returns :selector_not_found for no match", %{page: page, fixture: fixture} do
      {:ok, _} = Page.navigate(page, fixture)
      assert {:error, {:selector_not_found, "#nope"}} = Page.type(page, "#nope", "x")
    end

    test "press/4 Enter submits a form from a focused field", %{page: page, fixture: fixture} do
      {:ok, _} = Page.navigate(page, fixture)
      assert :ok = Page.type(page, "#search", "hi")
      assert :ok = Page.press(page, "#search", "Enter")
      assert {:ok, "submitted"} = Page.text(page, "#greeting")
    end

    test "press/4 with a nil selector targets the focused element", %{page: page, fixture: fixture} do
      {:ok, _} = Page.navigate(page, fixture)
      # type/4 focuses #search; press(nil, ...) must reach the still-focused field.
      assert :ok = Page.type(page, "#search", "hi")
      assert :ok = Page.press(page, nil, "Enter")
      assert {:ok, "submitted"} = Page.text(page, "#greeting")
    end

    test "press/4 returns :selector_not_found for no match", %{page: page, fixture: fixture} do
      {:ok, _} = Page.navigate(page, fixture)
      assert {:error, {:selector_not_found, "#nope"}} = Page.press(page, "#nope", "Enter")
    end

    test "press/4 returns :unknown_key for an unsupported key", %{page: page, fixture: fixture} do
      {:ok, _} = Page.navigate(page, fixture)
      assert {:error, {:unknown_key, "F13"}} = Page.press(page, "#search", "F13")
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

    test "wait_for_selector matches attribute selectors regardless of CSS quote style", %{
      page: page,
      fixture: fixture
    } do
      {:ok, _} = Page.navigate(page, fixture)

      # Single-quoted attribute value — the selector itself contains characters
      # ('\'') that must not corrupt the JS expression injected into Runtime.evaluate.
      assert :ok = Page.wait_for_selector(page, "[id^='ticket-card-']", timeout: 2_000)

      # Double-quoted attribute value — same property, with the inner-quote char
      # swapped. A single-pattern JS literal can only escape one of the two safely.
      assert :ok = Page.wait_for_selector(page, ~S([id^="ticket-card-"]), timeout: 2_000)

      # A double-quoted attribute selector whose value contains a space.
      assert :ok = Page.wait_for_selector(page, ~S([data-name="foo bar"]), timeout: 2_000)

      # The deepest case: a double-quoted attribute selector whose value itself
      # contains a literal quote character (`a'b`). This is exactly what a naive
      # string-concat path is most likely to break on.
      assert :ok = Page.wait_for_selector(page, ~S([data-label="a'b"]), timeout: 2_000)
    end

    test "wait_for_selector surfaces a JS exception instead of polling forever", %{
      page: page,
      fixture: fixture
    } do
      {:ok, _} = Page.navigate(page, fixture)

      # A syntactically invalid CSS selector that querySelector throws on.
      # (Chrome is lenient about some malformed selectors — e.g. an unclosed
      # `[foo` returns null silently — so pick one that actually throws.) The
      # fatal arm returns the exception instantly, so a passing run never nears
      # the timeout; the short 2s ceiling only bounds a regression. Asserting on
      # the SyntaxError text makes a future Chrome-leniency change fail loudly
      # here rather than silently degrade into a slow not-found timeout.
      assert {:error, {:evaluate_exception, details}} =
               Page.wait_for_selector(page, ":::", timeout: 2_000)

      assert get_in(details, ["exception", "description"]) =~ "not a valid selector"
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

      # navigate/3 waits for networkAlmostIdle, which for a trivial page can fire before
      # the main-frame `load` (lifecycle is matched by name, not loaderId, so there is no
      # guaranteed ordering between the two). Gate on document.readyState == "complete" so
      # the no-nav :load wait below starts from a definitively post-load state and cannot
      # catch a trailing `load` event — the source of the #67 flake (a fresh subscriber
      # only receives future events, so once `load` is in the past the wait must time out).
      assert eventually(fn ->
               match?({:ok, "complete"}, Page.evaluate(page, "document.readyState"))
             end)

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

  describe "with_page :deadline" do
    # Throwaway-browser deadlines include the launch: leave a cold Chrome on a slow
    # runner room to start, and fail loudly (not vacuously) if it didn't.
    @launch_headroom_deadline 6_000

    test "tears down a throwaway browser under a blocked wait and reaps Chrome", %{
      fixture: fixture
    } do
      {elapsed_us, result} =
        :timer.tc(fn ->
          CDPEx.with_page(
            [],
            fn page ->
              Process.put(:os_pid, chrome_os_pid(page))
              {:ok, _} = Page.navigate(page, fixture)
              Page.wait_for_selector(page, "#never-appears", timeout: 60_000)
            end,
            deadline: @launch_headroom_deadline
          )
        end)

      assert is_integer(Process.get(:os_pid)), "launch didn't complete within the deadline"
      assert result == {:error, :deadline_exceeded}
      assert elapsed_us >= @launch_headroom_deadline * 1_000
      # Teardown reaps Chrome before returning (kill + wait for exit, ~3.5s worst case).
      assert elapsed_us < (@launch_headroom_deadline + 6_000) * 1_000
      assert Process.info(self(), :trap_exit) == {:trap_exit, true}
      assert Process.info(self(), :messages) == {:messages, []}
      assert Process.info(self(), :monitors) == {:monitors, []}
      # Last: System.cmd's port leaves its own {:EXIT, port, :normal} in a trapping caller.
      refute os_alive?(Process.get(:os_pid))
    end

    test "catches a fun that sleeps past it at its next page call", %{fixture: fixture} do
      started_at = System.monotonic_time(:millisecond)

      result =
        CDPEx.with_page(
          [],
          fn page ->
            Process.put(:os_pid, chrome_os_pid(page))
            elapsed = System.monotonic_time(:millisecond) - started_at
            Process.sleep(max(@launch_headroom_deadline - elapsed, 0) + 500)
            Process.put(:navigate, Page.navigate(page, fixture))
          end,
          deadline: @launch_headroom_deadline
        )

      assert is_integer(Process.get(:os_pid)), "launch didn't complete within the deadline"
      assert result == {:error, :deadline_exceeded}
      # The verdict alone would hold even if nothing were torn down.
      assert {:error, _} = Process.get(:navigate)
      assert Process.info(self(), :messages) == {:messages, []}
      refute os_alive?(Process.get(:os_pid))
    end

    test "reaps Chrome when the caller dies during the launch" do
      before = our_chromes()
      parent = self()

      caller =
        spawn(fn ->
          fun = fn _ ->
            send(parent, :fun_started)
            Process.sleep(:infinity)
          end

          CDPEx.with_page([], fun, deadline: 60_000)
        end)

      assert eventually(fn -> our_chromes() -- before != [] end, 250),
             "Chrome never started"

      Process.exit(caller, :kill)
      refute_received :fun_started, "the kill landed after the launch, not during it"

      # The Browser finishes init, then its link to the dead caller stops it.
      assert eventually(fn -> our_chromes() -- before == [] end, 1_000),
             "Chrome outlived its caller: #{inspect(our_chromes() -- before)}"
    end

    test "returns fun's value untouched when it finishes in time", %{fixture: fixture} do
      result =
        CDPEx.with_page(
          [],
          fn page ->
            {:ok, _} = Page.navigate(page, fixture)
            Page.text(page, "#greeting")
          end,
          deadline: 30_000
        )

      assert result == {:ok, "Hello"}
      assert Process.info(self(), :messages) == {:messages, []}
      assert Process.info(self(), :monitors) == {:monitors, []}
    end

    test "still propagates a raise when it does not fire" do
      assert_raise RuntimeError, "boom", fn ->
        CDPEx.with_page([], fn _page -> raise "boom" end, deadline: 30_000)
      end

      assert Process.info(self(), :messages) == {:messages, []}
    end

    test "contains the teardown for a caller that does not trap exits" do
      parent = self()

      {caller, ref} =
        spawn_monitor(fn ->
          fun = fn page ->
            send(parent, :fun_started)
            Page.wait_for_selector(page, "#never", timeout: 60_000)
          end

          result = CDPEx.with_page([], fun, deadline: @launch_headroom_deadline)
          send(parent, {:result, result, Process.info(self(), [:trap_exit, :messages])})
        end)

      assert_receive :fun_started, @launch_headroom_deadline, "launch didn't complete"
      assert_receive {:result, {:error, :deadline_exceeded}, info}, 15_000
      assert info == [trap_exit: false, messages: []]
      assert_receive {:DOWN, ^ref, :process, ^caller, :normal}, 5_000
    end

    test "stops a connect: browser under a blocked wait and leaves Chrome running", %{
      fixture: fixture
    } do
      {:ok, a} = CDPEx.launch()
      on_exit(fn -> stop_quietly(a) end)
      %{host: host, port: port} = :sys.get_state(a)

      {elapsed_us, result} =
        :timer.tc(fn ->
          CDPEx.with_page(
            [connect: "http://#{host}:#{port}"],
            fn page ->
              {:ok, _} = Page.navigate(page, fixture)
              Process.put(:waiting, true)
              Page.wait_for_selector(page, "#never-appears", timeout: 60_000)
            end,
            deadline: 3_000
          )
        end)

      assert Process.get(:waiting), "fun didn't reach its wait within the deadline"
      assert result == {:error, :deadline_exceeded}
      assert elapsed_us < 9_000_000
      assert Process.info(self(), :messages) == {:messages, []}
      assert {:ok, page} = CDPEx.new_page(a, transport: :session)
      {:ok, _} = Page.navigate(page, fixture)
      assert {:ok, "Hello"} = Page.text(page, "#greeting")
    end

    test "through Pool.with_page/3 the pooled browser serves the next checkout", %{
      fixture: fixture
    } do
      {:ok, pool} = Pool.start_link(size: 1)
      on_exit(fn -> stop_pool_quietly(pool) end)

      {elapsed_us, result} =
        :timer.tc(fn ->
          Pool.with_page(
            pool,
            fn page ->
              Process.put(:browser, page.browser)
              {:ok, _} = Page.navigate(page, fixture)
              Page.wait_for_selector(page, "#never-appears", timeout: 60_000)
            end,
            deadline: 3_000
          )
        end)

      browser = Process.get(:browser)
      assert is_pid(browser), "fun didn't start within the deadline"
      assert result == {:error, :deadline_exceeded}
      assert elapsed_us < 9_000_000
      assert :sys.get_state(browser).pages == %{}

      assert {^browser, {:ok, "Hello"}} =
               Pool.with_page(pool, fn page ->
                 {:ok, _} = Page.navigate(page, fixture)
                 {page.browser, Page.text(page, "#greeting")}
               end)
    end

    test "a real launch cut short by the capped launch_timeout" do
      {elapsed_us, result} =
        :timer.tc(fn -> CDPEx.with_page([], fn _ -> :ran end, deadline: 50) end)

      assert result == {:error, :deadline_exceeded}
      # The failed launch kills Chrome and waits for it before returning.
      assert elapsed_us < 5_000_000
      assert Process.info(self(), :messages) == {:messages, []}
    end

    test "a deadline that passes during a real new_page skips fun and closes the page" do
      {:ok, browser} = CDPEx.launch()
      on_exit(fn -> stop_quietly(browser) end)

      # A Browser busy past the deadline, as when it is serving another caller's
      # new_page: the call is served once it resumes.
      :ok = :sys.suspend(browser)
      _resumer = spawn(fn -> Process.sleep(1_500) && :sys.resume(browser) end)

      result = CDPEx.with_page(browser, fn _ -> Process.put(:ran, true) end, deadline: 500)

      assert result == {:error, :deadline_exceeded}
      assert Process.get(:ran) == nil
      assert :sys.get_state(browser).pages == %{}
      assert Process.info(self(), :messages) == {:messages, []}
    end

    test "closes only the page on a caller-owned browser", %{fixture: fixture} do
      {:ok, browser} = CDPEx.launch()
      on_exit(fn -> stop_quietly(browser) end)

      {elapsed_us, result} =
        :timer.tc(fn ->
          CDPEx.with_page(
            browser,
            fn page ->
              Process.put(:target_id, page.target_id)
              {:ok, _} = Page.navigate(page, fixture)
              Page.wait_for_selector(page, "#never-appears", timeout: 60_000)
            end,
            deadline: 3_000
          )
        end)

      assert is_binary(Process.get(:target_id)), "fun didn't start within the deadline"
      assert result == {:error, :deadline_exceeded}
      # Bounds the teardown, not just the verdict: an uninterrupted wait takes 60s.
      assert elapsed_us < 9_000_000
      assert Process.alive?(browser)
      refute Map.has_key?(:sys.get_state(browser).pages, Process.get(:target_id))

      assert {:ok, "Hello"} =
               CDPEx.with_page(browser, fn page ->
                 {:ok, _} = Page.navigate(page, fixture)
                 Page.text(page, "#greeting")
               end)
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

  defp clicks(page) do
    {:ok, clicks} = Page.evaluate(page, "window.clicks")
    clicks
  end

  defp chrome_os_pid(page), do: :sys.get_state(page.browser).chrome.os_pid

  # OS pids of the Chromes this BEAM launched (children of its erl_child_setup), so a
  # parallel test run on the same machine doesn't count.
  defp our_chromes do
    {out, 0} = System.cmd("ps", ["-A", "-o", "pid=,ppid=,command="])

    rows =
      for line <- String.split(out, "\n", trim: true),
          [pid, ppid, cmd] <- [String.split(String.trim(line), ~r/\s+/, parts: 3)],
          do: {pid, ppid, cmd}

    beam = System.pid()
    setups = for {pid, ^beam, cmd} <- rows, cmd =~ "erl_child_setup", do: pid
    for {pid, ppid, cmd} <- rows, ppid in setups, cmd =~ "cdp_ex-", do: pid
  end

  defp os_alive?(os_pid) do
    match?({_, 0}, System.cmd("kill", ["-0", to_string(os_pid)], stderr_to_stdout: true))
  end

  # The Browser holds its own detach subscription; count only the wait's.
  defp detach_watched?(page) do
    page.conn
    |> :sys.get_state()
    |> Map.fetch!(:subscribers)
    |> Map.get("Target.detachedFromTarget", %{})
    |> Map.delete(page.browser)
    |> map_size() > 0
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
