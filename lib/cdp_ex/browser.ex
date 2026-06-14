defmodule CDPEx.Browser do
  @moduledoc """
  A GenServer owning a headless Chrome OS process and its CDP connections.

  `CDPEx.Browser` launches Chrome (via `CDPEx.Chrome`), opens a browser-level
  `CDPEx.Connection`, and creates pages on demand. It is the lifecycle owner:

    * It **traps exits** and links every connection, so a page connection crash
      is isolated (the page is dropped; the browser and other pages survive),
      while a browser-connection or Chrome death stops the browser cleanly.
    * For a **launched** browser, `terminate/2` always runs `CDPEx.Chrome.stop/1`
      — the no-orphan guarantee. Because that relies on `terminate/2`, supervise a
      launched browser with a `:shutdown` timeout, **not** `:brutal_kill`.

  A browser started via `CDPEx.connect/2` (connect-mode, `chrome: nil`) is the
  exception: it never launched Chrome, so `terminate/2` only closes the pages it
  opened and never reaps the remote process — `:brutal_kill` is harmless there.

  Most callers use the `CDPEx` facade rather than this module directly.
  """

  use GenServer

  alias CDPEx.Chrome
  alias CDPEx.Connection
  alias CDPEx.Fetch
  alias CDPEx.Page
  alias CDPEx.Protocol
  alias CDPEx.Proxy
  alias CDPEx.Telemetry

  require Logger

  @create_timeout 10_000
  @bootstrap_timeout 10_000
  # Ceiling for the synchronous proxy-auth arm during new_page (see reply_proxy_authed_page).
  @arm_timeout 15_000

  defstruct [
    :chrome,
    :browser_conn,
    :host,
    :port,
    :opts,
    :parent,
    :proxy_auth,
    # connect-mode (attached to a Chrome we didn't launch): drives the :session
    # default + the :dedicated rejection in new_page. Distinct from `chrome: nil`,
    # which a launched browser never is in production but a unit fixture can be.
    connected: false,
    pages: %{},
    sessions: %{},
    auths: %{},
    intercepts: %{},
    pending_auth: %{}
  ]

  @type t :: %__MODULE__{}

  # ── Public API ──────────────────────────────────────────────────────────────

  @doc """
  Starts a browser. See `CDPEx.Chrome` for launch options.

  Pass `:owner` (a pid) to set the process whose death triggers the browser's cleanup,
  overriding the default (the calling process). `CDPEx.Pool` uses this when adopting a
  browser it launched in a short-lived task.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {gen_opts, launch_opts} = Keyword.split(opts, [:name])
    GenServer.start_link(__MODULE__, launch_opts, gen_opts)
  end

  @doc false
  def child_spec(opts) do
    # terminate/2 reaps Chrome (kill + busy-poll + temp-dir cleanup, up to ~3.5s);
    # give it headroom over the GenServer default (5s) so a supervisor never
    # :brutal_kills mid-teardown and orphans Chrome.
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, shutdown: 10_000}
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
  # The call timeout covers the worst-case internal budget — Target.createTarget
  # (@create_timeout) + bootstrap (up to ~4 × @bootstrap_timeout) + the proxy-auth arm
  # (@arm_timeout) — so a stalled stage can't make the caller give up while the Browser is
  # still working, which would orphan an armed page. Normal new_page returns in well under
  # a second; this is only the pathological ceiling.
  def new_page(browser, opts \\ []), do: GenServer.call(browser, {:new_page, opts}, 75_000)

  @doc """
  Closes a page opened with `new_page/2`.

  Returns `{:error, :unknown_page}` if the page does not belong to this browser
  (a handle from a different browser, or one that was already closed).
  """
  @spec close_page(GenServer.server(), Page.t()) :: :ok | {:error, :unknown_page}
  def close_page(browser, %Page{} = page), do: GenServer.call(browser, {:close_page, page}, 15_000)

  # Internal hop for `CDPEx.Page.authenticate/4`, which owns the input contract
  # (credential guards + `:source` validation). Not part of the public API.
  @doc false
  @spec authenticate(GenServer.server(), Page.t(), keyword()) :: :ok | {:error, term()}
  def authenticate(browser, %Page{} = page, opts) do
    GenServer.call(browser, {:authenticate, page, opts}, 15_000)
  end

  # Internal hops for `CDPEx.Page.enable/disable_request_interception/2`, which own the
  # public contract. Browser is the reservation + monitor authority: it records the
  # interception owner (so auth and interception are mutually exclusive per page) and
  # monitors it, auto-disabling Fetch if the owner dies. The actual subscribe +
  # `Fetch.enable` stay on the caller's process (subscriptions key on the subscriber).
  @doc false
  @spec reserve_interception(GenServer.server(), Page.t()) :: :ok | {:error, term()}
  def reserve_interception(browser, %Page{} = page) do
    GenServer.call(browser, {:reserve_interception, page}, 15_000)
  catch
    # A stalled or dead Browser must not crash the caller's interception-owner process
    # with a raw exit — surface it as an error like the other page ops do.
    :exit, _ -> {:error, :noproc}
  end

  @doc false
  @spec release_interception(GenServer.server(), Page.t()) :: :ok
  def release_interception(browser, %Page{} = page) do
    GenServer.call(browser, {:release_interception, page}, 15_000)
  catch
    # Best-effort: if the Browser is gone or stalled there's nothing to release, and a
    # raw exit must not blow up the caller's disable path.
    :exit, _ -> :ok
  end

  @doc """
  Stops the browser, closing all pages.

  A launched browser also kills its Chrome; a connected one (`CDPEx.connect/2`)
  closes only the pages it opened and leaves the remote Chrome running.
  """
  @spec stop(GenServer.server()) :: :ok
  def stop(browser), do: GenServer.stop(browser, :normal)

  # ── GenServer callbacks ─────────────────────────────────────────────────────

  @impl true
  def init(launch_opts) do
    Process.flag(:trap_exit, true)

    # An explicit `:owner` overrides the :$ancestors-derived parent. CDPEx.Pool passes it
    # when adopting a browser launched in a throwaway task, so the owner-death self-reap
    # (the {:EXIT, parent, _} clause) still targets the real owner (the pool) rather than
    # the already-dead task — otherwise a hard-killed pool would orphan the browser.
    {owner, launch_opts} = Keyword.pop(launch_opts, :owner)
    {connect_ws, launch_opts} = Keyword.pop(launch_opts, :connect)
    {conn_opts, launch_opts} = Keyword.pop(launch_opts, :conn_opts, [])

    cond do
      connect_ws && Keyword.has_key?(launch_opts, :proxy) ->
        # :proxy is a Chrome launch flag (--proxy-server); connect-mode launches no
        # Chrome, so it could never take effect. Reject rather than silently ignore it.
        {:stop, {:unsupported_with_connect, :proxy}}

      connect_ws ->
        # Connect-mode: attach to an already-running Chrome. No Chrome.launch, and
        # chrome: nil so terminate/2 never reaps a process we didn't start.
        connect_browser(nil, connect_ws, launch_opts, owner || parent_pid(), nil, conn_opts)

      true ->
        {proxy, launch_opts} = Keyword.pop(launch_opts, :proxy)

        with {:ok, proxy_auth, launch_opts} <- apply_proxy(proxy, launch_opts),
             {:ok, chrome} <- Chrome.launch(launch_opts) do
          connect_browser(
            chrome,
            chrome.debug_url,
            launch_opts,
            owner || parent_pid(),
            proxy_auth,
            []
          )
        else
          {:error, reason} -> {:stop, reason}
        end
    end
  end

  # Translate the `:proxy` launch option into a `--proxy-server` flag (appended to
  # `:extra_args`) plus the credentials to arm each page with. A bad proxy value stops
  # init with `{:invalid_proxy, _}`, surfaced from `launch/1` as `{:error, _}`.
  defp apply_proxy(nil, launch_opts), do: {:ok, nil, launch_opts}

  defp apply_proxy(proxy, launch_opts) do
    # The flag is appended to :extra_args, which a full :args override discards — and
    # then arming auth for a proxy Chrome never received would be worse than a no-op
    # (every page paused through Fetch, interception blocked, no actual proxy). Reject
    # the ambiguous combination: use :extra_args, or put --proxy-server in :args yourself.
    if Keyword.has_key?(launch_opts, :args) do
      {:error, {:invalid_proxy, :args_override}}
    else
      case Proxy.parse(proxy) do
        {:ok, parsed} ->
          arg = Proxy.to_arg(parsed)
          launch_opts = Keyword.update(launch_opts, :extra_args, [arg], &(&1 ++ [arg]))
          {:ok, Proxy.credentials(parsed), launch_opts}

        {:error, _reason} = error ->
          error
      end
    end
  end

  # Connect the browser WebSocket (the launched Chrome's debug URL, or a remote
  # endpoint for connect-mode where `chrome` is nil). If the connect fails, init/1
  # returns {:stop, _} *before* the GenServer loop starts, so terminate/2 never
  # runs — reap Chrome here (when we own it) or leak the OS process and temp profile.
  defp connect_browser(chrome, ws_url, launch_opts, parent, proxy_auth, conn_opts) do
    {_scheme, host, port, _path} = Protocol.parse_ws_url(ws_url)

    case Connection.start_link(ws_url, conn_opts) do
      {:ok, conn} ->
        # Prune session entries when their target ends (tab closed/crashed, or our
        # own close_page) so long-lived browsers don't accumulate stale sessions —
        # parity with the dedicated path, which self-prunes on a page-conn EXIT.
        # subscribe/2 is a GenServer.call: if the browser socket dropped in the
        # window after start_link, it exits — and since the GenServer loop hasn't
        # started, terminate/2 never runs, so reap Chrome (and the conn) here or
        # leak the OS process and temp profile, same as the start_link path below.
        try do
          Connection.subscribe(conn, "Target.detachedFromTarget")

          {:ok,
           %__MODULE__{
             chrome: chrome,
             connected: is_nil(chrome),
             browser_conn: conn,
             host: host,
             port: port,
             opts: launch_opts,
             parent: parent,
             proxy_auth: proxy_auth
           }}
        catch
          :exit, reason ->
            safe_close(conn)
            if chrome, do: Chrome.stop(chrome)
            {:stop, reason}
        end

      {:error, reason} ->
        if chrome, do: Chrome.stop(chrome)
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
    # A connected browser defaults to :session and can't do :dedicated yet —
    # a per-page socket would have to target the remote host.
    default = if state.connected, do: :session, else: :dedicated

    case Keyword.get(opts, :transport, default) do
      :dedicated when state.connected ->
        {:reply, {:error, {:unsupported_transport, :dedicated}}, state}

      :dedicated ->
        reply_dedicated_page(state, opts)

      :session ->
        reply_session_page(state, opts)

      other ->
        {:reply, {:error, {:invalid_transport, other}}, state}
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
        Telemetry.page(:stop, %{target_id: tid, transport: :session})
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
        Telemetry.page(:stop, %{target_id: tid, transport: :dedicated})
        {:reply, :ok, %{state | pages: Map.delete(state.pages, tid)}}

      _ ->
        # Not one of this browser's pages (a handle from another browser, or one
        # already closed). Don't close the handle's connection or send a stray
        # closeTarget — doing so could stop a live page owned by another browser.
        {:reply, {:error, :unknown_page}, state}
    end
  end

  def handle_call({:authenticate, %Page{session_id: sid}, _opts}, _from, state)
      when not is_nil(sid) do
    # A :session page rides the shared browser connection, which `close_page/2`
    # never stops — so the Fetch handler (which self-stops when its connection goes
    # down) would linger for the life of the browser. Restrict authenticate/4 to
    # :dedicated pages rather than leak a handler per authenticated session page.
    {:reply, {:error, {:unsupported_transport, :session}}, state}
  end

  def handle_call(
        {:authenticate, %Page{conn: conn, target_id: tid, session_id: sid}, opts},
        from,
        state
      ) do
    # Dedicated page only (the :session clause above already returned).
    cond do
      Map.get(state.pages, tid) != conn ->
        # Not one of this browser's live pages (a handle from another browser, or an
        # already-closed one) — mirror close_page/2 instead of arming a handler on a
        # foreign connection and linking it to us.
        {:reply, {:error, :unknown_page}, state}

      Map.has_key?(state.intercepts, tid) ->
        # Request interception is active on this page; both drive the Fetch domain, so
        # arming auth would clobber the interceptor. Enforce mutual exclusion.
        {:reply, {:error, {:conflict, :intercepting}}, state}

      Map.has_key?(state.auths, tid) ->
        # Already authenticated: a second handler would double every
        # continueRequest/continueWithAuth, and its teardown would disable Fetch for
        # the survivor. Reject the re-arm.
        {:reply, {:error, :already_authenticated}, state}

      true ->
        # Start a per-page Fetch handler linked to us (crash-isolated, dies with the
        # browser). It arms asynchronously and signals {:armed, pid} when ready; we
        # park the caller's `from` in pending_auth and reply only then, so
        # authenticate/4 still returns once interception is armed — without blocking
        # this GenServer for the whole enable. It self-stops when the page's connection
        # goes down; we drop the auths entry when it exits (see the {:EXIT, …} clause).
        #
        # We also MONITOR the caller: if its 15s authenticate/4 call times out (a slow
        # arm under scheduler starvation), the caller exits and we'd otherwise leave the
        # page armed with auths[tid] set but no waiting caller — a retry would hit
        # {:error, :already_authenticated} with no way to recover but closing the page.
        # On the caller's :DOWN we cancel the orphaned handler so its {:EXIT} clears
        # auths[tid] and the page becomes re-authenticatable (#40).
        fetch_opts =
          [conn: conn, session_id: sid, browser: self()] ++
            Keyword.take(opts, [:username, :password, :source])

        case Fetch.start_link(fetch_opts) do
          {:ok, pid} ->
            {caller, _tag} = from
            caller_ref = Process.monitor(caller)

            {:noreply,
             %{
               state
               | auths: Map.put(state.auths, tid, pid),
                 pending_auth: Map.put(state.pending_auth, pid, {from, caller_ref})
             }}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
    end
  end

  def handle_call({:reserve_interception, %Page{session_id: sid}}, _from, state)
      when not is_nil(sid) do
    # Same shared-connection problem authenticate/4 rejects: an interception owner on a
    # :session page would outlive close_page (which never stops the shared connection).
    {:reply, {:error, {:unsupported_transport, :session}}, state}
  end

  def handle_call({:reserve_interception, %Page{conn: conn, target_id: tid}}, {caller, _tag}, state) do
    cond do
      Map.get(state.pages, tid) != conn ->
        {:reply, {:error, :unknown_page}, state}

      Map.has_key?(state.auths, tid) ->
        {:reply, {:error, {:conflict, :authenticated}}, state}

      Map.has_key?(state.intercepts, tid) ->
        {:reply, {:error, :already_intercepting}, state}

      true ->
        # Monitor (not link) the foreign caller; on its death we auto-disable Fetch so
        # a crashed/forgetful owner can't leave the page bricked with no resolver.
        ref = Process.monitor(caller)
        {:reply, :ok, %{state | intercepts: Map.put(state.intercepts, tid, {caller, ref})}}
    end
  end

  def handle_call({:release_interception, %Page{target_id: tid}}, _from, state) do
    case Map.pop(state.intercepts, tid) do
      {nil, _} ->
        {:reply, :ok, state}

      {{_caller, ref}, intercepts} ->
        Process.demonitor(ref, [:flush])
        {:reply, :ok, %{state | intercepts: intercepts}}
    end
  end

  @impl true
  def handle_info({port, {:exit_status, status}}, %{chrome: %{port: port}} = state) do
    Logger.warning("[CDPEx.Browser] Chrome exited with status #{status}")
    Telemetry.error(status, :chrome_exited)
    {:stop, {:chrome_exited, status}, state}
  end

  def handle_info({:EXIT, pid, reason}, %{browser_conn: pid} = state) do
    Telemetry.error(reason, :browser_connection_down)
    {:stop, browser_down_reason(reason), state}
  end

  def handle_info({:EXIT, pid, reason}, %{parent: pid} = state) do
    # Our owner (supervisor or the process that called CDPEx.launch) died. Shut
    # down with the same reason so `terminate/2` reaps Chrome — otherwise a
    # supervisor `:shutdown` would leave an orphaned browser and OS process.
    {:stop, reason, state}
  end

  def handle_info({:EXIT, pid, reason}, state) do
    # A page connection or a Fetch auth handler exited (closed or crashed). If a Fetch
    # handler was still arming, its authenticate/4 caller is parked on a delayed reply
    # in pending_auth — fail it with the exit reason rather than let it hang to the
    # call timeout. Then drop the pid from both maps: a stale page handle's next op
    # returns {:error, :noproc}, and clearing the auths entry lets the page be
    # authenticated again.
    state =
      case Map.pop(state.pending_auth, pid) do
        {nil, _} ->
          state

        {{from, caller_ref}, pending_auth} ->
          Process.demonitor(caller_ref, [:flush])
          GenServer.reply(from, {:error, reason})
          %{state | pending_auth: pending_auth}
      end

    {:noreply, %{state | pages: drop_conn(state.pages, pid), auths: drop_value(state.auths, pid)}}
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

  def handle_info({:armed, pid}, state) do
    # A Fetch handler finished arming; reply :ok to the authenticate/4 caller parked in
    # pending_auth and release our monitor on it. Unknown pid → the caller already
    # departed (its :DOWN dropped the entry and cancelled this handler), so this is an
    # orphan whose cancel-stop {:EXIT} will clear auths — ignore the late signal.
    case Map.pop(state.pending_auth, pid) do
      {nil, _} ->
        {:noreply, state}

      {{from, caller_ref}, pending_auth} ->
        Process.demonitor(caller_ref, [:flush])
        GenServer.reply(from, :ok)
        {:noreply, %{state | pending_auth: pending_auth}}
    end
  end

  def handle_info({:arm_failed, pid, reason}, state) do
    # A Fetch handler couldn't arm; fail the parked authenticate/4 caller and drop the
    # (already-recorded) auths entry so the page can be authenticated again. The
    # handler stops :normal, so this is the quiet failure path (no crash report); the
    # {:EXIT} clause below is the fallback if a handler dies without signalling.
    # Unknown pid → the caller already departed; its {:EXIT} clears auths, so ignore.
    case Map.pop(state.pending_auth, pid) do
      {nil, _} ->
        {:noreply, state}

      {{from, caller_ref}, pending_auth} ->
        Process.demonitor(caller_ref, [:flush])
        GenServer.reply(from, {:error, reason})
        {:noreply, %{state | pending_auth: pending_auth, auths: drop_value(state.auths, pid)}}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    # An interception owner died without disabling. Drop its reservation and disable
    # Fetch on that page's connection so the page isn't left bricked with no resolver.
    # The disable runs OFF the Browser process (a hung page conn must not stall every
    # other page — the same responsiveness #36 protects for auth).
    case pop_intercept_by_ref(state.intercepts, ref) do
      {nil, _} ->
        # Not an interception owner — maybe an authenticate/4 caller that departed (its
        # 15s call timed out) while its Fetch handler was still arming.
        cancel_orphaned_auth(state, ref)

      {tid, intercepts} ->
        case Map.get(state.pages, tid) do
          # Page already closed: its Fetch domain went with it, nothing to disable.
          nil -> :ok
          conn -> disable_fetch_async(conn)
        end

        {:noreply, %{state | intercepts: intercepts}}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # An authenticate/4 caller we were monitoring (while its Fetch handler armed) went
  # down — typically because its 15s call timed out on a slow arm. If a pending entry
  # still matches the monitor ref, cancel the orphaned handler: it disables Fetch and
  # stops, and its {:EXIT} clears the auths entry so the page can be authenticated again
  # instead of being stuck on {:error, :already_authenticated} (#40). We do not reply —
  # the caller is gone. Unknown ref → a stale monitor; ignore.
  #
  # Unlike the {:armed}/{:arm_failed}/{:EXIT} paths, this one does NOT demonitor: a
  # monitor is one-shot and the runtime already removed it when it delivered the :DOWN
  # that brought us here, so there is nothing left to demonitor.
  defp cancel_orphaned_auth(state, ref) do
    case pop_pending_auth_by_ref(state.pending_auth, ref) do
      {nil, _} ->
        {:noreply, state}

      {fetch_pid, pending_auth} ->
        Fetch.cancel(fetch_pid)
        {:noreply, %{state | pending_auth: pending_auth}}
    end
  end

  # Find and remove the pending_auth entry whose caller monitor ref matches `ref`,
  # returning {fetch_pid, remaining}. pending_auth is tiny (typically 0–1 entries).
  defp pop_pending_auth_by_ref(pending_auth, ref) do
    case Enum.find(pending_auth, fn {_pid, {_from, caller_ref}} -> caller_ref == ref end) do
      nil -> {nil, pending_auth}
      {fetch_pid, _entry} -> {fetch_pid, Map.delete(pending_auth, fetch_pid)}
    end
  end

  # Best-effort Fetch.disable for a dead interception owner, on a throwaway process so
  # an unresponsive page connection can't block the Browser GenServer. Connection.call
  # tolerates a dead conn (returns {:error, _} rather than exiting); a genuine failure
  # on a live conn is logged since it can leave the page intercepted.
  defp disable_fetch_async(conn) do
    _ =
      Task.start(fn ->
        case Connection.call(conn, "Fetch.disable", %{}, @create_timeout) do
          {:ok, _} ->
            :ok

          {:error, :noproc} ->
            :ok

          {:error, {:ws_closed, _}} ->
            :ok

          {:error, reason} ->
            Logger.warning(
              "[CDPEx.Browser] Fetch.disable after interception owner death returned #{inspect(reason)}; the page may remain intercepted"
            )
        end
      end)

    :ok
  end

  @impl true
  def terminate(_reason, state) do
    # Stop the page and browser connections best-effort (a conn may already be
    # dying — its exit must not abort us before Chrome.stop/1, the no-orphan
    # guarantee). Closing browser_conn here makes teardown deterministic instead
    # of leaving it to stop reactively when its socket drops on Chrome exit.
    _ =
      if state.connected and Process.alive?(state.browser_conn) do
        # Connect-mode: we don't own Chrome, so closing the socket wouldn't reap the
        # tabs we opened. Close just OUR targets (best-effort; close_target tolerates
        # a dead conn), leaving Chrome and any pre-existing tabs untouched.
        Enum.each(state.sessions, fn {tid, _sid} -> close_target(state.browser_conn, tid) end)
        Enum.each(state.pages, fn {tid, _conn} -> close_target(state.browser_conn, tid) end)
      end

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
        Telemetry.page(:start, %{target_id: page.target_id, transport: :dedicated})
        state = %{state | pages: Map.put(state.pages, page.target_id, page.conn)}

        case state.proxy_auth do
          nil -> {:reply, {:ok, page}, state}
          creds -> reply_proxy_authed_page(state, page, creds)
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  # Browser launched with an authenticated `:proxy`: arm this page's proxy auth before
  # returning it, so the caller navigates straight away (no manual authenticate/4). Done
  # synchronously within new_page — which already blocks the Browser for target creation +
  # bootstrap — so it needs none of the async pending_auth machinery authenticate/4 uses
  # for its separate, concurrently-served call. The Fetch handler is recorded in `auths`
  # exactly like authenticate/4, so mutual exclusion with interception and the
  # drop-on-EXIT teardown apply unchanged. On any arm failure the just-created page (never
  # handed to the caller) is closed and the error surfaced.
  defp reply_proxy_authed_page(state, %Page{conn: conn, target_id: tid} = page, creds) do
    fetch_opts = [
      conn: conn,
      session_id: nil,
      browser: self(),
      username: creds.username,
      password: creds.password,
      source: :proxy
    ]

    case Fetch.start_link(fetch_opts) do
      {:ok, pid} ->
        case await_fetch_armed(pid) do
          :ok ->
            {:reply, {:ok, page}, %{state | auths: Map.put(state.auths, tid, pid)}}

          {:error, reason} ->
            {:reply, {:error, reason}, close_failed_auth_page(state, tid, conn)}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, close_failed_auth_page(state, tid, conn)}
    end
  end

  # The proxy-auth arm failed; the just-created page was never handed to the caller, so
  # close its target + connection and drop it from `pages` (best-effort — either may
  # already be gone). Returns the updated state for the {:reply, …} tuple.
  defp close_failed_auth_page(state, tid, conn) do
    safe_close(conn)
    close_target(state.browser_conn, tid)
    %{state | pages: Map.delete(state.pages, tid)}
  end

  # Block (inside the new_page call) until the Fetch handler signals it's armed. It is
  # linked and we trap exits, so a crash arrives as {:EXIT, pid, _}. Bounded by
  # @arm_timeout; on timeout cancel the handler so it can't linger. A late {:armed}/{:EXIT}
  # for this pid arriving after we return is handled harmlessly by the handle_info clauses
  # (on success the pid is in `auths`, so drop-on-EXIT applies; otherwise it's a no-op).
  defp await_fetch_armed(pid) do
    receive do
      {:armed, ^pid} -> :ok
      {:arm_failed, ^pid, reason} -> {:error, reason}
      {:EXIT, ^pid, reason} -> {:error, reason}
    after
      @arm_timeout ->
        Fetch.cancel(pid)
        {:error, :timeout}
    end
  end

  defp reply_session_page(%{proxy_auth: creds} = state, _opts) when not is_nil(creds) do
    # An authenticated proxy needs per-page Fetch auth, only supported on :dedicated pages
    # (a :session page rides the shared connection close_page never stops). Reject rather
    # than hand back a session page that can't answer the proxy challenge.
    {:reply, {:error, {:unsupported_transport, :session}}, state}
  end

  defp reply_session_page(state, opts) do
    case open_session_page(state, opts) do
      {:ok, page} ->
        Telemetry.page(:start, %{target_id: page.target_id, transport: :session})
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
    page_url = "ws://#{bracket_host(state.host)}:#{state.port}/devtools/page/#{tid}"

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

  defp drop_value(map, pid) do
    map |> Enum.reject(fn {_k, v} -> v == pid end) |> Map.new()
  end

  # Pop the interception entry whose monitor ref matches, returning {tid, rest} — or
  # {nil, intercepts} if none matches (a stale monitor we no longer track).
  defp pop_intercept_by_ref(intercepts, ref) do
    case Enum.find(intercepts, fn {_tid, {_caller, r}} -> r == ref end) do
      nil -> {nil, intercepts}
      {tid, _entry} -> {tid, Map.delete(intercepts, tid)}
    end
  end

  # Close a CDP target on the browser connection, ignoring failures (the browser
  # conn may be gone, or the target already closed).
  defp close_target(browser_conn, tid) do
    _ = Connection.call(browser_conn, "Target.closeTarget", %{"targetId" => tid}, @create_timeout)
    :ok
  end

  # Bracket an IPv6 literal so the page WebSocket URL is well-formed
  # (`ws://[::1]:9222/…` rather than the malformed `ws://::1:9222/…`).
  defp bracket_host(host) do
    if String.contains?(host, ":"), do: "[#{host}]", else: host
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
