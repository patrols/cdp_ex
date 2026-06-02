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

  defstruct [:chrome, :browser_conn, :host, :port, :opts, :parent, pages: %{}, sessions: %{}]

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
    * `:transport` — `:dedicated` (default, one WebSocket per page, strong crash
      isolation) or `:session` (multiplexed over the browser socket via a
      flattened CDP session — fewer sockets, but all session pages share the
      browser connection's fate: if it drops, they all go). Any other value
      returns `{:error, {:invalid_transport, value}}`.
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
        # Prune session entries when their target ends (tab closed/crashed, or our
        # own close_page) so long-lived browsers don't accumulate stale sessions —
        # parity with the dedicated path, which self-prunes on a page-conn EXIT.
        Connection.subscribe(conn, "Target.detachedFromTarget")

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
    case Keyword.get(opts, :transport, :dedicated) do
      :dedicated -> reply_dedicated_page(state, opts)
      :session -> reply_session_page(state, opts)
      other -> {:reply, {:error, {:invalid_transport, other}}, state}
    end
  end

  def handle_call({:close_page, %Page{target_id: tid, session_id: sid}}, _from, state)
      when not is_nil(sid) do
    case Map.get(state.sessions, tid) do
      ^sid ->
        # The page rides the shared browser connection; detach the session and
        # close the tab, but NEVER close that connection (other sessions use it).
        detach_session(state.browser_conn, sid)
        close_target(state.browser_conn, tid)
        {:reply, :ok, %{state | sessions: Map.delete(state.sessions, tid)}}

      _ ->
        {:reply, {:error, :unknown_page}, state}
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
    {:stop, browser_down_reason(reason), state}
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

  def handle_info(
        {:cdp_event, conn, "Target.detachedFromTarget", params, _session_id},
        %{browser_conn: conn} = state
      ) do
    # A flattened session ended. Drop its entry so it doesn't linger for the life
    # of the browser. Idempotent: our own close_page may have removed it already,
    # and a targetId we don't track is simply a no-op delete.
    {:noreply, %{state | sessions: Map.delete(state.sessions, params["targetId"])}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    # Stop the page and browser connections best-effort (a conn may already be
    # dying — its exit must not abort us before Chrome.stop/1, the no-orphan
    # guarantee). Closing browser_conn here makes teardown deterministic instead
    # of leaving it to stop reactively when its socket drops on Chrome exit.
    Enum.each(state.pages, fn {_tid, conn} -> safe_close(conn) end)
    safe_close(state.browser_conn)
    if state.chrome, do: Chrome.stop(state.chrome)
    :ok
  end

  # The browser connection went down. A clean close — `{:shutdown, {:ws_closed, _}}`,
  # the Connection's own graceful-stop contract when its socket drops (e.g. Chrome
  # going away on teardown) — is expected, so stop with a :shutdown reason and the
  # GenServer logs nothing. Any other reason is a genuine fault and stays loud.
  defp browser_down_reason({:shutdown, {:ws_closed, _}} = reason),
    do: {:shutdown, {:browser_connection_down, reason}}

  defp browser_down_reason(reason), do: {:browser_connection_down, reason}

  # ── page creation ───────────────────────────────────────────────────────────

  defp reply_dedicated_page(state, opts) do
    case open_page(state, opts) do
      {:ok, page} ->
        {:reply, {:ok, page}, %{state | pages: Map.put(state.pages, page.target_id, page.conn)}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp reply_session_page(state, opts) do
    case open_session_page(state, opts) do
      {:ok, page} ->
        sessions = Map.put(state.sessions, page.target_id, page.session_id)
        {:reply, {:ok, page}, %{state | sessions: sessions}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

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

  # The session transport: create a target, attach with `flatten: true` (its
  # frames then arrive on the browser connection tagged with the sessionId), and
  # bootstrap it over that shared connection. On any failure NEVER `safe_close`
  # browser_conn — it is shared by every other session.
  defp open_session_page(state, opts) do
    case Connection.call(
           state.browser_conn,
           "Target.createTarget",
           %{"url" => "about:blank"},
           @create_timeout
         ) do
      {:ok, %{"targetId" => tid}} -> attach_session(state, tid, opts)
      {:error, reason} -> {:error, reason}
    end
  end

  defp attach_session(state, tid, opts) do
    case Connection.call(
           state.browser_conn,
           "Target.attachToTarget",
           %{"targetId" => tid, "flatten" => true},
           @create_timeout
         ) do
      {:ok, %{"sessionId" => sid}} ->
        case bootstrap_page(state.browser_conn, sid, opts) do
          :ok ->
            {:ok, %Page{browser: self(), conn: state.browser_conn, target_id: tid, session_id: sid}}

          {:error, reason} ->
            detach_session(state.browser_conn, sid)
            close_target(state.browser_conn, tid)
            {:error, reason}
        end

      {:error, reason} ->
        close_target(state.browser_conn, tid)
        {:error, reason}
    end
  end

  # Detach a session on the browser connection, ignoring failures.
  defp detach_session(browser_conn, session_id) do
    _ =
      Connection.call(
        browser_conn,
        "Target.detachFromTarget",
        %{"sessionId" => session_id},
        @create_timeout
      )

    :ok
  end

  defp bootstrap_page(conn, opts), do: bootstrap_page(conn, nil, opts)

  defp bootstrap_page(conn, session_id, opts) do
    with {:ok, _} <- bcall(conn, session_id, "Page.enable", %{}),
         {:ok, _} <- bcall(conn, session_id, "Runtime.enable", %{}),
         {:ok, _} <-
           bcall(conn, session_id, "Page.setLifecycleEventsEnabled", %{"enabled" => true}) do
      maybe_prevent_alerts(conn, session_id, opts)
    end
  end

  # One bootstrap CDP call, scoped to `session_id` (nil for a dedicated page).
  defp bcall(conn, session_id, method, params) do
    Connection.call(conn, method, params, @bootstrap_timeout, session_id: session_id)
  end

  defp maybe_prevent_alerts(conn, session_id, opts) do
    if Keyword.get(opts, :prevent_alerts, true) do
      params = %{"source" => Protocol.prevent_alerts_js()}

      case bcall(conn, session_id, "Page.addScriptToEvaluateOnNewDocument", params) do
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
