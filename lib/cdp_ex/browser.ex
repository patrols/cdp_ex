defmodule CDPEx.Browser do
  @moduledoc """
  A GenServer owning a headless Chrome OS process and its CDP connections.

  `CDPEx.Browser` launches Chrome (via `CDPEx.Chrome`), opens a browser-level
  `CDPEx.Connection`, and creates pages on demand. It is the lifecycle owner:

    * It **traps exits** and links every connection, so a page connection crash
      is isolated (the page is dropped; the browser and other pages survive),
      while a browser-connection or Chrome death stops the browser cleanly.
    * `terminate/2` always runs `CDPEx.Chrome.stop/1` — the no-orphan guarantee.
      Because that relies on `terminate/2`, supervise this with a `:shutdown`
      timeout, **not** `:brutal_kill`.

  Most callers use the `CDPEx` facade rather than this module directly.
  """

  use GenServer

  alias CDPEx.Chrome
  alias CDPEx.Connection
  alias CDPEx.Page
  alias CDPEx.Protocol

  require Logger

  @create_timeout 10_000
  @bootstrap_timeout 10_000

  defstruct [:chrome, :browser_conn, :host, :port, :opts, :parent, pages: %{}]

  @type t :: %__MODULE__{}

  # ── Public API ──────────────────────────────────────────────────────────────

  @doc "Starts a browser. See `CDPEx.Chrome` for launch options."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {gen_opts, launch_opts} = Keyword.split(opts, [:name])
    GenServer.start_link(__MODULE__, launch_opts, gen_opts)
  end

  @doc """
  Opens a new page (tab) and returns a `CDPEx.Page` handle.

  Options:
    * `:prevent_alerts` — inject no-op `alert`/`confirm`/`prompt` (default `true`)
  """
  @spec new_page(GenServer.server(), keyword()) :: {:ok, Page.t()} | {:error, term()}
  def new_page(browser, opts \\ []), do: GenServer.call(browser, {:new_page, opts}, 30_000)

  @doc """
  Closes a page opened with `new_page/2`.

  Returns `{:error, :unknown_page}` if the page does not belong to this browser
  (a handle from a different browser, or one that was already closed).
  """
  @spec close_page(GenServer.server(), Page.t()) :: :ok | {:error, :unknown_page}
  def close_page(browser, %Page{} = page), do: GenServer.call(browser, {:close_page, page}, 15_000)

  @doc "Stops the browser, closing all pages and killing Chrome."
  @spec stop(GenServer.server()) :: :ok
  def stop(browser), do: GenServer.stop(browser, :normal)

  # ── GenServer callbacks ─────────────────────────────────────────────────────

  @impl true
  def init(launch_opts) do
    Process.flag(:trap_exit, true)

    case Chrome.launch(launch_opts) do
      {:ok, chrome} -> connect_browser(chrome, launch_opts)
      {:error, reason} -> {:stop, reason}
    end
  end

  # Chrome is running now. If the browser WebSocket fails to connect, init/1
  # returns {:stop, _} *before* the GenServer loop starts, so terminate/2 never
  # runs — we must reap Chrome here or leak the OS process and temp profile.
  defp connect_browser(chrome, launch_opts) do
    {host, port, _path} = Protocol.parse_ws_url(chrome.debug_url)

    case Connection.start_link(chrome.debug_url) do
      {:ok, conn} ->
        {:ok,
         %__MODULE__{
           chrome: chrome,
           browser_conn: conn,
           host: host,
           port: port,
           opts: launch_opts,
           parent: parent_pid()
         }}

      {:error, reason} ->
        Chrome.stop(chrome)
        {:stop, reason}
    end
  end

  # The process that called start_link — our linked "owner" (a supervisor, or the
  # caller of CDPEx.launch). We trap exits, so when it dies we must shut down and
  # reap Chrome rather than mistaking its exit for a page connection's.
  defp parent_pid do
    case Process.get(:"$ancestors") do
      [pid | _] when is_pid(pid) -> pid
      [name | _] when is_atom(name) -> Process.whereis(name)
      _ -> nil
    end
  end

  @impl true
  def handle_call({:new_page, opts}, _from, state) do
    case open_page(state, opts) do
      {:ok, page} ->
        {:reply, {:ok, page}, %{state | pages: Map.put(state.pages, page.target_id, page.conn)}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:close_page, %Page{target_id: tid, conn: conn}}, _from, state) do
    case Map.get(state.pages, tid) do
      ^conn ->
        # Close the target on the browser connection first (a page connection can't
        # cleanly close its own target), then stop the page connection — best-effort,
        # since either may already be gone.
        close_target(state.browser_conn, tid)
        safe_close(conn)
        {:reply, :ok, %{state | pages: Map.delete(state.pages, tid)}}

      _ ->
        # Not one of this browser's pages (a handle from another browser, or one
        # already closed). Don't close the handle's connection or send a stray
        # closeTarget — doing so could stop a live page owned by another browser.
        {:reply, {:error, :unknown_page}, state}
    end
  end

  @impl true
  def handle_info({port, {:exit_status, status}}, %{chrome: %{port: port}} = state) do
    Logger.warning("[CDPEx.Browser] Chrome exited with status #{status}")
    {:stop, {:chrome_exited, status}, state}
  end

  def handle_info({:EXIT, pid, reason}, %{browser_conn: pid} = state) do
    {:stop, {:browser_connection_down, reason}, state}
  end

  def handle_info({:EXIT, pid, reason}, %{parent: pid} = state) do
    # Our owner (supervisor or the process that called CDPEx.launch) died. Shut
    # down with the same reason so `terminate/2` reaps Chrome — otherwise a
    # supervisor `:shutdown` would leave an orphaned browser and OS process.
    {:stop, reason, state}
  end

  def handle_info({:EXIT, pid, _reason}, state) do
    # A page connection exited (closed or crashed). Drop it; the page handle the
    # caller holds becomes stale and its next op returns {:error, :noproc}.
    {:noreply, %{state | pages: drop_conn(state.pages, pid)}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    # Stop page connections best-effort (a conn may already be dying — its exit
    # must not abort us before Chrome.stop/1, which is the no-orphan guarantee).
    Enum.each(state.pages, fn {_tid, conn} -> safe_close(conn) end)
    if state.chrome, do: Chrome.stop(state.chrome)
    :ok
  end

  # ── page creation ───────────────────────────────────────────────────────────

  defp open_page(state, opts) do
    case Connection.call(
           state.browser_conn,
           "Target.createTarget",
           %{"url" => "about:blank"},
           @create_timeout
         ) do
      {:ok, %{"targetId" => tid}} -> open_target(state, tid, opts)
      {:error, reason} -> {:error, reason}
    end
  end

  # The target exists now, so any failure past this point must close it (and the
  # page connection, if opened) — otherwise we leak a Chrome tab/socket that
  # isn't tracked in state.pages and can't be cleaned up deterministically.
  defp open_target(state, tid, opts) do
    page_url = "ws://#{state.host}:#{state.port}/devtools/page/#{tid}"

    case Connection.start_link(page_url) do
      {:ok, conn} ->
        case bootstrap_page(conn, opts) do
          :ok ->
            {:ok, %Page{browser: self(), conn: conn, target_id: tid}}

          {:error, reason} ->
            safe_close(conn)
            close_target(state.browser_conn, tid)
            {:error, reason}
        end

      {:error, reason} ->
        close_target(state.browser_conn, tid)
        {:error, reason}
    end
  end

  defp bootstrap_page(conn, opts) do
    with {:ok, _} <- Connection.call(conn, "Page.enable", %{}, @bootstrap_timeout),
         {:ok, _} <- Connection.call(conn, "Runtime.enable", %{}, @bootstrap_timeout),
         {:ok, _} <-
           Connection.call(
             conn,
             "Page.setLifecycleEventsEnabled",
             %{"enabled" => true},
             @bootstrap_timeout
           ) do
      maybe_prevent_alerts(conn, opts)
    end
  end

  defp maybe_prevent_alerts(conn, opts) do
    if Keyword.get(opts, :prevent_alerts, true) do
      params = %{"source" => Protocol.prevent_alerts_js()}

      case Connection.call(
             conn,
             "Page.addScriptToEvaluateOnNewDocument",
             params,
             @bootstrap_timeout
           ) do
        {:ok, _} -> :ok
        error -> error
      end
    else
      :ok
    end
  end

  defp drop_conn(pages, pid) do
    pages |> Enum.reject(fn {_tid, conn} -> conn == pid end) |> Map.new()
  end

  # Close a CDP target on the browser connection, ignoring failures (the browser
  # conn may be gone, or the target already closed).
  defp close_target(browser_conn, tid) do
    _ = Connection.call(browser_conn, "Target.closeTarget", %{"targetId" => tid}, @create_timeout)
    :ok
  end

  # Stop a page connection, tolerating an already-dead process. `Connection.close/1`
  # is a `GenServer.stop`, which exits with `:noproc` if the process is gone — that
  # exit must never propagate out of teardown.
  defp safe_close(conn) do
    if Process.alive?(conn), do: Connection.close(conn)
    :ok
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end
end
