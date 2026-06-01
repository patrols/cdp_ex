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

  alias CDPEx.FixtureServer
  alias CDPEx.Page

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

    test "wait_for_selector resolves for present and times out for absent", %{
      page: page,
      fixture: fixture
    } do
      {:ok, _} = Page.navigate(page, fixture)
      assert :ok = Page.wait_for_selector(page, "#greeting", timeout: 2_000)
      assert {:error, :timeout} = Page.wait_for_selector(page, "#does-not-exist", timeout: 300)
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
end
