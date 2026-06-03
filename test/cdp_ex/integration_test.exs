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

  alias CDPEx.Connection
  alias CDPEx.FixtureServer
  alias CDPEx.Page
  alias CDPEx.Pool

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
  end

  # Teardown helper. The browser is linked to (and watches) the test process, so
  # by the time on_exit runs it may already be stopping on its own — racing this
  # call. Tolerate an exit from the stop so a teardown race never fails a test
  # whose body already passed.
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
end
