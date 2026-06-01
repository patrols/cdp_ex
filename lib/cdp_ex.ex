defmodule CDPEx do
  @moduledoc """
  OTP-native Chrome DevTools Protocol (CDP) browser automation for Elixir.

  `CDPEx` launches a headless Chrome process and drives it directly over the
  Chrome DevTools Protocol on a `Mint.WebSocket` connection — no ChromeDriver
  and no Node.js. Browsers and their WebSocket connections are supervised
  processes, so a Chrome crash surfaces to callers as `{:error, reason}` rather
  than a hung session.

  This module is the high-level facade. See `CDPEx.Page` for page operations.

  ## Example

      {:ok, browser} = CDPEx.launch()
      {:ok, page} = CDPEx.new_page(browser)
      {:ok, _page} = CDPEx.Page.navigate(page, "https://example.com")
      {:ok, html} = CDPEx.Page.html(page)
      :ok = CDPEx.stop(browser)

  Or, resource-safe, with `with_page/3`:

      CDPEx.with_page([], fn page ->
        {:ok, _} = CDPEx.Page.navigate(page, "https://example.com")
        CDPEx.Page.html(page)
      end)

  > #### Status {: .info}
  >
  > v0.1 is single-browser, one-WebSocket-per-page, headless-Chrome only.
  > Connection pooling, `sessionId` multiplexing, and network interception are
  > out of scope for this release.
  """

  alias CDPEx.Browser
  alias CDPEx.Page

  @doc """
  Launches a headless Chrome browser and returns its process pid.

  Accepts the launch options documented in `CDPEx.Chrome` (e.g. `:headless`,
  `:chrome_binary`, `:extra_args`, `:window_size`). For long-lived use, prefer
  putting `CDPEx.Browser` under your own supervisor with a `:shutdown` timeout.
  """
  @spec launch(keyword()) :: GenServer.on_start()
  def launch(opts \\ []), do: Browser.start_link(opts)

  @doc "Stops a browser started with `launch/1`, closing all pages and killing Chrome."
  @spec stop(pid()) :: :ok
  def stop(browser), do: Browser.stop(browser)

  @doc "Opens a new page. See `CDPEx.Browser.new_page/2` for options."
  @spec new_page(pid(), keyword()) :: {:ok, Page.t()} | {:error, term()}
  def new_page(browser, opts \\ []), do: Browser.new_page(browser, opts)

  @doc "Closes a page opened with `new_page/2`."
  @spec close_page(pid(), Page.t()) :: :ok
  def close_page(browser, page), do: Browser.close_page(browser, page)

  @doc """
  Runs `fun` with a fresh page, guaranteeing the page (and, when given launch
  options, the browser) is cleaned up afterwards — even if `fun` raises.

  Pass an existing browser pid to reuse it, or a keyword list of launch options
  to spin up a throwaway browser for the duration of the call. Returns whatever
  `fun` returns, or `{:error, reason}` if the page/browser could not be created.

      # against an existing browser
      CDPEx.with_page(browser, fn page ->
        {:ok, _} = CDPEx.Page.navigate(page, "https://example.com")
        CDPEx.Page.html(page)
      end)

      # throwaway browser + page
      CDPEx.with_page([headless: true], &CDPEx.Page.html/1)
  """
  @spec with_page(pid() | keyword(), (Page.t() -> result), keyword()) ::
          result | {:error, term()}
        when result: var
  def with_page(browser_or_opts, fun, opts \\ [])

  def with_page(browser, fun, opts) when is_pid(browser) and is_function(fun, 1) do
    case new_page(browser, opts) do
      {:ok, page} ->
        try do
          fun.(page)
        after
          close_page(browser, page)
        end

      {:error, _} = error ->
        error
    end
  end

  def with_page(launch_opts, fun, opts) when is_list(launch_opts) and is_function(fun, 1) do
    case launch(launch_opts) do
      {:ok, browser} ->
        try do
          with_page(browser, fun, opts)
        after
          stop(browser)
        end

      {:error, _} = error ->
        error
    end
  end
end
