defmodule CDPEx.Connection do
  @moduledoc """
  A GenServer owning a single CDP WebSocket connection.

  This is the heart of `cdp_ex`'s OTP model. It connects and upgrades a
  `Mint.WebSocket` in `init/1`, then runs in `:active` mode so every inbound
  frame arrives as a process message in `handle_info/2`. The GenServer:

    * matches command **replies** back to the caller by JSON-RPC `id`
      (concurrent callers are fine — each `call/4` blocks only its own caller),
    * routes unsolicited **events** to subscribers and one-shot waiters,
    * answers WebSocket **pings** with pongs,
    * fails every pending caller with `{:error, {:ws_closed, reason}}` and stops
      if the socket drops — no caller is left hanging.

  One connection backs one socket: the browser endpoint, or a page endpoint at
  `/devtools/page/<targetId>`. A single connection may carry both untagged
  browser/page frames and many flattened sessions' frames, demultiplexed by
  `sessionId`. `CDPEx.Browser` starts and monitors these.
  """

  use GenServer, restart: :temporary

  alias CDPEx.Protocol
  alias Mint.HTTP
  alias Mint.WebSocket

  require Logger

  @upgrade_timeout 15_000
  @default_call_timeout 10_000

  defstruct [
    :conn,
    :ref,
    :websocket,
    next_id: 1,
    pending: %{},
    subscribers: %{},
    all_subscribers: MapSet.new(),
    monitors: %{},
    waiters: [],
    ws_send_error: nil
  ]

  @type t :: %__MODULE__{}

  # ── Public API ──────────────────────────────────────────────────────────────

  @doc """
  Starts a connection to the given `ws://host:port/path` URL.

  Options: `:upgrade_timeout` (ms, default 15_000) and `:name` (registers the
  GenServer). Returns `{:ok, pid}` once the WebSocket handshake completes.
  """
  @spec start_link(String.t(), keyword()) :: GenServer.on_start()
  def start_link(ws_url, opts \\ []) do
    {gen_opts, conn_opts} = Keyword.split(opts, [:name])
    GenServer.start_link(__MODULE__, {ws_url, conn_opts}, gen_opts)
  end

  @typedoc """
  Error reasons from `call/5` — and from every `Network`/`Page` op layered on it.
  Precisely specced (not `term()`) so Dialyzer flags drift at the source.
  """
  @type call_error ::
          {:cdp_error, String.t(), term()}
          | {:timeout, String.t()}
          | {:ws_closed, term()}
          | :noproc

  @doc """
  Sends a CDP command and blocks until its reply (or `timeout`).

  Returns `{:ok, result}`, `{:error, {:cdp_error, method, error}}` on a protocol
  error, `{:error, {:timeout, method}}`, or `{:error, {:ws_closed, reason}}` /
  `{:error, :noproc}` if the connection drops or is already gone.

  Pass `opts` with `session_id: sid` to address a flattened CDP session.
  """
  @spec call(GenServer.server(), String.t(), map(), timeout(), keyword()) ::
          {:ok, map()} | {:error, call_error()}
  def call(conn, method, params \\ %{}, timeout \\ @default_call_timeout, opts \\ []) do
    session_id = Keyword.get(opts, :session_id)
    # Outer GenServer deadline is slightly longer than the CDP timeout so our own
    # `{:timeout, method}` reply wins over a raw GenServer.call timeout.
    GenServer.call(conn, {:cdp_call, method, params, timeout, session_id}, call_deadline(timeout))
  catch
    :exit, {:noproc, _} -> {:error, :noproc}
    :exit, {:normal, _} -> {:error, :noproc}
    :exit, {{:shutdown, {:ws_closed, reason}}, _} -> {:error, {:ws_closed, reason}}
    :exit, {:shutdown, _} -> {:error, :noproc}
    # Under scheduler starvation the outer GenServer.call deadline (timeout + 1s)
    # can fire before our inner {:call_timeout} reply — return the documented
    # timeout tuple rather than letting the raw exit crash the caller.
    :exit, {:timeout, _} -> {:error, {:timeout, method}}
  end

  @doc """
  Subscribes the calling process to a CDP event method (e.g.
  `"Page.lifecycleEvent"`) or to `:all` events. Delivered as
  `{:cdp_event, conn_pid, method, params, session_id}` — `session_id` is `nil`
  for browser/page-level events.

  The subscription is removed automatically if the subscribing process exits, so
  a crashed subscriber can't accumulate in the connection.
  """
  @spec subscribe(GenServer.server(), String.t() | :all) :: :ok
  def subscribe(conn, method), do: GenServer.call(conn, {:subscribe, method, self()})

  @doc "Removes a subscription created with `subscribe/2`."
  @spec unsubscribe(GenServer.server(), String.t() | :all) :: :ok
  def unsubscribe(conn, method), do: GenServer.call(conn, {:unsubscribe, method, self()})

  @doc """
  Blocks until an event for which `matcher.(params)` returns true, or `timeout`.

  `matcher` receives the event params map. Returns `{:ok, params}` (the matched
  event's params) on a match, or `{:error, reason}` where reason is
  `{:timeout, :await_event}` (no matching event in time) or `:noproc` /
  `{:ws_closed, _}` (the connection itself went away) — callers must be able to
  tell those apart.

  Pass `opts` with `session_id: sid` to only match events from that session.
  """
  @spec await_event(GenServer.server(), (map() -> boolean()), timeout(), keyword()) ::
          {:ok, map()} | {:error, {:timeout, :await_event} | :noproc | {:ws_closed, term()}}
  def await_event(conn, matcher, timeout \\ @default_call_timeout, opts \\ [])
      when is_function(matcher, 1) do
    session_id = Keyword.get(opts, :session_id)
    GenServer.call(conn, {:await_event, matcher, timeout, session_id}, call_deadline(timeout))
  catch
    :exit, {:noproc, _} -> {:error, :noproc}
    :exit, {:normal, _} -> {:error, :noproc}
    :exit, {{:shutdown, {:ws_closed, reason}}, _} -> {:error, {:ws_closed, reason}}
    :exit, {:shutdown, _} -> {:error, :noproc}
    :exit, {:timeout, _} -> {:error, {:timeout, :await_event}}
  end

  @doc "Closes the WebSocket and stops the connection."
  @spec close(GenServer.server()) :: :ok
  def close(conn), do: GenServer.stop(conn, :normal)

  # ── GenServer callbacks ─────────────────────────────────────────────────────

  # Mint.WebSocket.new/4's success typing interacts badly with Dialyzer: it infers
  # the {:ok, conn, websocket} branch unreachable (claims new/4 only returns
  # {:error, ...}). That's a false positive — every connection test establishes a
  # socket through this branch at runtime. Suppress just this one tiny callback.
  @dialyzer {:nowarn_function, init: 1}

  @impl true
  def init({ws_url, opts}) do
    {host, port, path} = Protocol.parse_ws_url(ws_url)
    upgrade_timeout = Keyword.get(opts, :upgrade_timeout, @upgrade_timeout)

    # The handshake runs synchronously in init so its frames can't interleave
    # with post-upgrade CDP frames.
    with {:ok, conn} <- HTTP.connect(:http, host, port, protocols: [:http1]),
         {:ok, conn, ref} <- WebSocket.upgrade(:ws, conn, path, []),
         {:ok, conn, status, headers} <- recv_upgrade(conn, ref, upgrade_timeout),
         {:ok, conn, websocket} <- WebSocket.new(conn, ref, status, headers) do
      # Trap exits only AFTER the handshake. During the upgrade, recv_upgrade's
      # wildcard receive would otherwise swallow an owner {:EXIT} (it reaches
      # WebSocket.stream → :unknown → loop), so a dying owner is ignored until the
      # upgrade timeout. Deferred, a mid-handshake owner death takes this still-
      # linked process down (aborting the connect); post-handshake we trap so an
      # owner exit stops us cleanly via the {:EXIT, _, _} handler + terminate/2.
      Process.flag(:trap_exit, true)
      {:ok, %__MODULE__{conn: conn, ref: ref, websocket: websocket}}
    else
      {:error, reason} -> {:stop, {:ws_connect, reason}}
      {:error, _conn, reason} -> {:stop, {:ws_upgrade, reason}}
    end
  end

  @impl true
  def handle_call({:cdp_call, method, params, timeout, session_id}, from, state) do
    id = state.next_id
    payload = Protocol.encode(method, params, id, session_id)
    key = {id, session_id}

    case ws_send(state, payload) do
      {:ok, state} ->
        timer = arm_timeout({:call_timeout, key}, timeout)
        pending = Map.put(state.pending, key, {from, method, timer})
        {:noreply, %{state | next_id: id + 1, pending: pending}}

      {:error, state, reason} ->
        # A failed socket write means this connection can no longer be trusted:
        # reply with the documented {:ws_closed, _} shape (not the internal
        # {:ws_send,_}/{:ws_encode,_} tuple), fail any other pending callers, and
        # stop — so the next caller doesn't keep trying on a dead socket.
        GenServer.reply(from, {:error, {:ws_closed, reason}})
        stop_ws_closed(state, reason)
    end
  end

  def handle_call({:subscribe, :all, pid}, _from, state) do
    state = monitor_subscriber(state, pid)
    {:reply, :ok, %{state | all_subscribers: MapSet.put(state.all_subscribers, pid)}}
  end

  def handle_call({:subscribe, method, pid}, _from, state) do
    state = monitor_subscriber(state, pid)
    subs = Map.update(state.subscribers, method, MapSet.new([pid]), &MapSet.put(&1, pid))
    {:reply, :ok, %{state | subscribers: subs}}
  end

  def handle_call({:unsubscribe, :all, pid}, _from, state) do
    state = %{state | all_subscribers: MapSet.delete(state.all_subscribers, pid)}
    {:reply, :ok, demonitor_if_orphaned(state, pid)}
  end

  def handle_call({:unsubscribe, method, pid}, _from, state) do
    subs = Map.update(state.subscribers, method, MapSet.new(), &MapSet.delete(&1, pid))
    state = %{state | subscribers: subs}
    {:reply, :ok, demonitor_if_orphaned(state, pid)}
  end

  def handle_call({:await_event, matcher, timeout, session_id}, from, state) do
    timer = arm_timeout({:waiter_timeout, from}, timeout)
    {:noreply, %{state | waiters: [{matcher, session_id, from, timer} | state.waiters]}}
  end

  @impl true
  def handle_info({:call_timeout, key}, state) do
    case Map.pop(state.pending, key) do
      {nil, _} ->
        {:noreply, state}

      {{from, method, _timer}, pending} ->
        GenServer.reply(from, {:error, {:timeout, method}})
        {:noreply, %{state | pending: pending}}
    end
  end

  def handle_info({:waiter_timeout, from}, state) do
    case pop_waiter(state.waiters, from) do
      {nil, _waiters} ->
        {:noreply, state}

      {_waiter, waiters} ->
        GenServer.reply(from, {:error, {:timeout, :await_event}})
        {:noreply, %{state | waiters: waiters}}
    end
  end

  # A subscriber process died without unsubscribing: drop it from every
  # subscription and forget its monitor, so dead pids can't accumulate. Must come
  # before the catch-all clause, which would otherwise feed it to WebSocket.stream.
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    {:noreply, drop_subscriber(state, pid)}
  end

  # A linked process — our owner (e.g. CDPEx.Browser) — went down. Stop too, so
  # terminate/2 closes the socket. This makes cleanup unconditional even when the
  # owner skips its own terminate/2 (a :brutal_kill, or a crash before cleanup);
  # otherwise the connection would linger with an open socket until Chrome drops it.
  def handle_info({:EXIT, _pid, reason}, state) do
    {:stop, reason, state}
  end

  # Any other message is an inbound WebSocket transport frame.
  def handle_info(message, state) do
    case WebSocket.stream(state.conn, message) do
      {:ok, conn, responses} ->
        state = %{state | conn: conn}

        case Protocol.decode_frames(state.websocket, responses, state.ref) do
          {:ok, websocket, frames} ->
            dispatch_frames(frames, %{state | websocket: websocket})

          {:error, reason} ->
            stop_ws_closed(state, reason)
        end

      {:error, conn, reason, _responses} ->
        stop_ws_closed(%{state | conn: conn}, reason)

      :unknown ->
        {:noreply, state}
    end
  end

  @impl true
  def terminate(reason, state) do
    # Single fail point for every stop path (socket drop, close/1, owner exit):
    # reply to in-flight callers/waiters with the documented {:ws_closed, _} shape
    # (not the less precise :noproc they'd otherwise get from the dying process)
    # and cancel their timers so none fire into a dead mailbox.
    fail_all_pending(state, ws_closed_reason(reason))

    # Best-effort graceful close; the socket may already be gone.
    with %{websocket: ws, conn: conn, ref: ref} when not is_nil(ws) <- state,
         {:ok, _ws, data} <- WebSocket.encode(ws, :close),
         {:ok, conn} <- WebSocket.stream_request_body(conn, ref, data) do
      HTTP.close(conn)
    end

    :ok
  rescue
    _ -> :ok
  end

  # Map a stop reason to the {:ws_closed, _} reason reported to in-flight callers.
  defp ws_closed_reason({:shutdown, {:ws_closed, reason}}), do: {:ws_closed, reason}
  defp ws_closed_reason(_), do: {:ws_closed, :closed}

  # A dropped socket is a controlled end of this connection's life, not a crash:
  # stop under `:shutdown` (so OTP emits no crash report) carrying the clean
  # `{:ws_closed, reason}` shape — terminate/2 is the single place that fails the
  # pending callers. The owning Browser sees the reason via its monitor.
  defp stop_ws_closed(state, reason) do
    {:stop, {:shutdown, {:ws_closed, reason}}, state}
  end

  # ── frame dispatch ──────────────────────────────────────────────────────────

  # Process a batch of decoded frames. A peer close frame ends the connection:
  # dispatch everything before it (so any final replies/events still land), then
  # fail remaining callers with {:ws_closed, _} and stop — otherwise a graceful
  # close would be silently dropped and callers would only time out.
  defp dispatch_frames(frames, state) do
    {pre, rest} = Enum.split_while(frames, &(not close_frame?(&1)))
    state = Enum.reduce(pre, state, &dispatch/2)

    cond do
      # A failed pong write (recorded by pong/2 during the reduce) means the
      # socket is dead — stop now, mirroring a failed command write, rather than
      # running on it until the next ws_send notices.
      state.ws_send_error ->
        stop_ws_closed(state, state.ws_send_error)

      match?([_ | _], rest) ->
        stop_ws_closed(state, close_reason(hd(rest)))

      true ->
        {:noreply, state}
    end
  end

  defp close_frame?({:close, _code, _reason}), do: true
  defp close_frame?(_frame), do: false

  defp close_reason({:close, code, reason}), do: {:peer_closed, code, reason}

  defp dispatch(frame, state) do
    case Protocol.classify(frame) do
      {:reply, id, session_id, result} -> dispatch_reply({id, session_id}, result, state)
      {:event, method, session_id, params} -> dispatch_event(method, session_id, params, state)
      {:ping, data} -> pong(state, data)
      :ignore -> state
    end
  end

  defp dispatch_reply(key, result, state) do
    case Map.pop(state.pending, key) do
      {nil, _} ->
        state

      {{from, method, timer}, pending} ->
        cancel_timer(timer)
        GenServer.reply(from, normalize_reply(result, method))
        %{state | pending: pending}
    end
  end

  defp normalize_reply({:ok, result}, _method), do: {:ok, result}
  defp normalize_reply({:error, error}, method), do: {:error, {:cdp_error, method, error}}

  defp dispatch_event(method, session_id, params, state) do
    state
    |> notify_waiters(session_id, params)
    |> notify_subscribers(method, session_id, params)
  end

  defp notify_waiters(state, event_session_id, params) do
    {matched, kept} =
      Enum.split_with(state.waiters, fn {matcher, want_session_id, _from, _timer} ->
        session_match?(want_session_id, event_session_id) and safe_match(matcher, params)
      end)

    Enum.each(matched, fn {_matcher, _sid, from, timer} ->
      cancel_timer(timer)
      GenServer.reply(from, {:ok, params})
    end)

    %{state | waiters: kept}
  end

  # A session-less waiter (`nil`) matches any event — preserving the default
  # behavior; a session-scoped waiter only matches its own session's events.
  defp session_match?(nil, _event_session_id), do: true
  defp session_match?(session_id, session_id), do: true
  defp session_match?(_want, _event), do: false

  defp notify_subscribers(state, method, session_id, params) do
    method_subs = Map.get(state.subscribers, method, MapSet.new())

    method_subs
    |> MapSet.union(state.all_subscribers)
    |> Enum.each(fn pid -> send(pid, {:cdp_event, self(), method, params, session_id}) end)

    state
  end

  defp safe_match(matcher, params) do
    matcher.(params)
  rescue
    _ -> false
  catch
    # A caller-supplied matcher runs inside this connection process; a throw or
    # exit (not just a raise) must be contained here too, or it would take down
    # the socket owner and every other caller sharing it.
    :throw, _ -> false
    :exit, _ -> false
  end

  # ── subscriber lifecycle ────────────────────────────────────────────────────

  # Monitor a subscriber the first time it subscribes, so we learn if it dies.
  # At most one monitor per pid, however many methods it subscribes to.
  defp monitor_subscriber(state, pid) do
    if Map.has_key?(state.monitors, pid) do
      state
    else
      ref = Process.monitor(pid)
      %{state | monitors: Map.put(state.monitors, pid, ref)}
    end
  end

  # After an unsubscribe, release our monitor once the pid has no subscriptions
  # left — otherwise we'd hold a monitor for a fully-unsubscribed process.
  defp demonitor_if_orphaned(state, pid) do
    if subscribed_anywhere?(state, pid) do
      state
    else
      case Map.pop(state.monitors, pid) do
        {nil, _monitors} ->
          state

        {ref, monitors} ->
          _ = Process.demonitor(ref, [:flush])
          %{state | monitors: monitors}
      end
    end
  end

  defp subscribed_anywhere?(state, pid) do
    MapSet.member?(state.all_subscribers, pid) or
      Enum.any?(state.subscribers, fn {_method, set} -> MapSet.member?(set, pid) end)
  end

  # Remove a (dead) subscriber from every subscription and forget its monitor.
  defp drop_subscriber(state, pid) do
    subscribers =
      Map.new(state.subscribers, fn {method, set} -> {method, MapSet.delete(set, pid)} end)

    %{
      state
      | subscribers: subscribers,
        all_subscribers: MapSet.delete(state.all_subscribers, pid),
        monitors: Map.delete(state.monitors, pid)
    }
  end

  # ── websocket plumbing ──────────────────────────────────────────────────────

  defp ws_send(state, data) do
    # Protocol.encode returns iodata; WebSocket.encode requires a binary
    # text payload (its guard is is_binary/1), so flatten before framing.
    text = IO.iodata_to_binary(data)

    # Handle each step separately rather than a shared `else`: encode fails with
    # {:error, websocket, _} and stream_request_body with {:error, conn, _}. A
    # combined clause would need to match %Mint.WebSocket{} to tell them apart,
    # which breaks the struct's opaqueness (dialyzer). Splitting sidesteps that.
    case WebSocket.encode(state.websocket, {:text, text}) do
      {:ok, websocket, frame} ->
        state = %{state | websocket: websocket}

        case WebSocket.stream_request_body(state.conn, state.ref, frame) do
          {:ok, conn} -> {:ok, %{state | conn: conn}}
          {:error, conn, reason} -> {:error, %{state | conn: conn}, {:ws_send, reason}}
        end

      {:error, websocket, reason} ->
        {:error, %{state | websocket: websocket}, {:ws_encode, reason}}
    end
  end

  defp pong(state, data) do
    case WebSocket.encode(state.websocket, {:pong, data}) do
      {:ok, websocket, frame} ->
        case WebSocket.stream_request_body(state.conn, state.ref, frame) do
          {:ok, conn} ->
            %{state | websocket: websocket, conn: conn}

          # A failed pong write means the socket is dead. Record it so
          # dispatch_frames/2 stops the connection (mirroring ws_send/2's failure
          # handling) rather than running on a broken socket until the next
          # command write notices.
          {:error, conn, reason} ->
            %{state | websocket: websocket, conn: conn, ws_send_error: {:ws_send, reason}}
        end

      {:error, websocket, reason} ->
        %{state | websocket: websocket, ws_send_error: {:ws_encode, reason}}
    end
  end

  defp recv_upgrade(conn, ref, timeout) do
    # headers starts as [] (not nil) so its type stays a proper header list — this
    # lets Dialyzer prove the WebSocket.new/4 success branch in init/1 is reachable
    # (Mint's opaque types otherwise infer a nil header and flag it impossible).
    recv_upgrade(conn, ref, deadline(timeout), nil, [], false)
  end

  defp recv_upgrade(conn, _ref, _deadline, status, headers, true)
       when not is_nil(status) and is_list(headers) do
    {:ok, conn, status, headers}
  end

  defp recv_upgrade(conn, ref, deadline, status, headers, done) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      {:error, conn, :upgrade_timeout}
    else
      receive do
        message ->
          case WebSocket.stream(conn, message) do
            {:ok, conn, responses} ->
              {status, headers, done} = apply_upgrade(responses, ref, {status, headers, done})
              recv_upgrade(conn, ref, deadline, status, headers, done)

            {:error, conn, reason, _responses} ->
              {:error, conn, {:ws_stream, reason}}

            :unknown ->
              recv_upgrade(conn, ref, deadline, status, headers, done)
          end
      after
        remaining -> {:error, conn, :upgrade_timeout}
      end
    end
  end

  defp apply_upgrade(responses, ref, acc) do
    Enum.reduce(responses, acc, fn
      {:status, ^ref, status}, {_s, h, d} -> {status, h, d}
      {:headers, ^ref, headers}, {s, h, d} -> {s, h ++ headers, d}
      {:done, ^ref}, {s, h, _d} -> {s, h, true}
      _other, acc -> acc
    end)
  end

  # ── helpers ─────────────────────────────────────────────────────────────────

  defp fail_all_pending(state, reason) do
    Enum.each(state.pending, fn {_key, {from, _method, timer}} ->
      cancel_timer(timer)
      GenServer.reply(from, {:error, reason})
    end)

    # Reply waiters with the real failure reason (e.g. {:ws_closed, _}), not
    # {:error, :timeout} — a dropped socket must be distinguishable from a page
    # that simply never fired the awaited event.
    Enum.each(state.waiters, fn {_matcher, _session_id, from, timer} ->
      cancel_timer(timer)
      GenServer.reply(from, {:error, reason})
    end)
  end

  defp pop_waiter(waiters, from) do
    case Enum.split_with(waiters, fn {_m, _sid, f, _t} -> f == from end) do
      {[waiter | _], rest} -> {waiter, rest}
      {[], rest} -> {nil, rest}
    end
  end

  # Process.send_after/3 only accepts a non-negative integer delay. Map :infinity
  # to "no deadline" (a nil timer, which cancel_timer/1 tolerates) and a negative
  # delay (an already-elapsed computed deadline) to an immediate 0 — so no
  # bad-but-plausible timeout value can raise inside the GenServer and crash it.
  defp arm_timeout(_msg, :infinity), do: nil

  defp arm_timeout(msg, timeout) when is_integer(timeout) and timeout < 0,
    do: Process.send_after(self(), msg, 0)

  defp arm_timeout(msg, timeout), do: Process.send_after(self(), msg, timeout)

  defp cancel_timer(nil), do: :ok

  defp cancel_timer(timer) do
    # Process.cancel_timer returns time-left | false; we only call it for the
    # side effect, so normalise to :ok (otherwise the union return is flagged as
    # an unmatched value under --warnings-as-errors).
    _ = Process.cancel_timer(timer)
    :ok
  end

  defp call_deadline(:infinity), do: :infinity
  defp call_deadline(timeout) when is_integer(timeout), do: timeout + 1_000

  defp deadline(timeout), do: System.monotonic_time(:millisecond) + timeout
end
