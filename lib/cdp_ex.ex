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
  > Pages default to one WebSocket each (strong crash isolation); opt into
  > `sessionId` multiplexing (many pages over the one browser socket) with
  > `new_page(browser, transport: :session)`, trading isolation for fewer sockets.
  > Connection pooling, network interception, and stealth remain out of scope.
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

  @doc """
  Closes a page opened with `new_page/2`.

  Returns `{:error, :unknown_page}` if `page` was not opened on `browser`.
  """
  @spec close_page(pid(), Page.t()) :: :ok | {:error, :unknown_page}
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
          # Best-effort: the page/browser may have already exited, and a teardown
          # exit must not mask `fun`'s result or a raised exception.
          safe(fn -> close_page(browser, page) end)
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
          safe(fn -> stop(browser) end)
        end

      {:error, _} = error ->
        error
    end
  end

  # Run a teardown action, swallowing an already-dead-process exit (or any raise)
  # so cleanup in `with_page/3` never overrides the operation's real outcome.
  defp safe(fun) do
    fun.()
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end
end
