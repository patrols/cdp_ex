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
  `/devtools/page/<targetId>`. `CDPEx.Browser` starts and monitors these.
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
    waiters: []
  ]

  @type t :: %__MODULE__{}

  # ── Public API ──────────────────────────────────────────────────────────────

  @doc """
  Starts a connection to the given `ws://host:port/path` URL.

  Options: `:upgrade_timeout` (ms, default 15_000) plus any `GenServer`
  start options. Returns `{:ok, pid}` once the WebSocket handshake completes.
  """
  @spec start_link(String.t(), keyword()) :: GenServer.on_start()
  def start_link(ws_url, opts \\ []) do
    {gen_opts, conn_opts} = Keyword.split(opts, [:name])
    GenServer.start_link(__MODULE__, {ws_url, conn_opts}, gen_opts)
  end

  @doc """
  Sends a CDP command and blocks until its reply (or `timeout`).

  Returns `{:ok, result}`, `{:error, {:cdp_error, method, error}}` on a protocol
  error, `{:error, {:timeout, method}}`, or `{:error, {:ws_closed, reason}}` /
  `{:error, :noproc}` if the connection drops or is already gone.
  """
  @spec call(GenServer.server(), String.t(), map(), timeout()) ::
          {:ok, map()} | {:error, term()}
  def call(conn, method, params \\ %{}, timeout \\ @default_call_timeout) do
    # Outer GenServer deadline is slightly longer than the CDP timeout so our own
    # `{:timeout, method}` reply wins over a raw GenServer.call timeout.
    GenServer.call(conn, {:cdp_call, method, params, timeout}, call_deadline(timeout))
  catch
    :exit, {:noproc, _} -> {:error, :noproc}
    :exit, {:normal, _} -> {:error, :noproc}
    :exit, {{:shutdown, {:ws_closed, reason}}, _} -> {:error, {:ws_closed, reason}}
    :exit, {:shutdown, _} -> {:error, :noproc}
  end

  @doc """
  Subscribes the calling process to a CDP event method (e.g.
  `"Page.lifecycleEvent"`) or to `:all` events. Delivered as
  `{:cdp_event, conn_pid, method, params}`.
  """
  @spec subscribe(GenServer.server(), String.t() | :all) :: :ok
  def subscribe(conn, method), do: GenServer.call(conn, {:subscribe, method, self()})

  @doc "Removes a subscription created with `subscribe/2`."
  @spec unsubscribe(GenServer.server(), String.t() | :all) :: :ok
  def unsubscribe(conn, method), do: GenServer.call(conn, {:unsubscribe, method, self()})

  @doc """
  Blocks until an event for which `matcher.(params)` returns true, or `timeout`.

  `matcher` receives the event params map. Returns `:ok` on a match, or
  `{:error, reason}` where reason is `:timeout` (no matching event in time) or
  `:noproc` / `{:ws_closed, _}` (the connection itself went away) — callers must
  be able to tell those apart.
  """
  @spec await_event(GenServer.server(), (map() -> boolean()), timeout()) ::
          :ok | {:error, :timeout | :noproc | {:ws_closed, term()}}
  def await_event(conn, matcher, timeout \\ @default_call_timeout)
      when is_function(matcher, 1) do
    GenServer.call(conn, {:await_event, matcher, timeout}, call_deadline(timeout))
  catch
    :exit, {:noproc, _} -> {:error, :noproc}
    :exit, {:normal, _} -> {:error, :noproc}
    :exit, {{:shutdown, {:ws_closed, reason}}, _} -> {:error, {:ws_closed, reason}}
    :exit, {:shutdown, _} -> {:error, :noproc}
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
    Process.flag(:trap_exit, true)
    {host, port, path} = Protocol.parse_ws_url(ws_url)
    upgrade_timeout = Keyword.get(opts, :upgrade_timeout, @upgrade_timeout)

    # The handshake runs synchronously in init so its frames can't interleave
    # with post-upgrade CDP frames.
    with {:ok, conn} <- HTTP.connect(:http, host, port, protocols: [:http1]),
         {:ok, conn, ref} <- WebSocket.upgrade(:ws, conn, path, []),
         {:ok, conn, status, headers} <- recv_upgrade(conn, ref, upgrade_timeout),
         {:ok, conn, websocket} <- WebSocket.new(conn, ref, status, headers) do
      {:ok, %__MODULE__{conn: conn, ref: ref, websocket: websocket}}
    else
      {:error, reason} -> {:stop, {:ws_connect, reason}}
      {:error, _conn, reason} -> {:stop, {:ws_upgrade, reason}}
    end
  end

  @impl true
  def handle_call({:cdp_call, method, params, timeout}, from, state) do
    id = state.next_id
    payload = Protocol.encode(method, params, id)

    case ws_send(state, payload) do
      {:ok, state} ->
        timer = Process.send_after(self(), {:call_timeout, id}, timeout)
        pending = Map.put(state.pending, id, {from, method, timer})
        {:noreply, %{state | next_id: id + 1, pending: pending}}

      {:error, state, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:subscribe, :all, pid}, _from, state) do
    {:reply, :ok, %{state | all_subscribers: MapSet.put(state.all_subscribers, pid)}}
  end

  def handle_call({:subscribe, method, pid}, _from, state) do
    subs = Map.update(state.subscribers, method, MapSet.new([pid]), &MapSet.put(&1, pid))
    {:reply, :ok, %{state | subscribers: subs}}
  end

  def handle_call({:unsubscribe, :all, pid}, _from, state) do
    {:reply, :ok, %{state | all_subscribers: MapSet.delete(state.all_subscribers, pid)}}
  end

  def handle_call({:unsubscribe, method, pid}, _from, state) do
    subs = Map.update(state.subscribers, method, MapSet.new(), &MapSet.delete(&1, pid))
    {:reply, :ok, %{state | subscribers: subs}}
  end

  def handle_call({:await_event, matcher, timeout}, from, state) do
    timer = Process.send_after(self(), {:waiter_timeout, from}, timeout)
    {:noreply, %{state | waiters: [{matcher, from, timer} | state.waiters]}}
  end

  @impl true
  def handle_info({:call_timeout, id}, state) do
    case Map.pop(state.pending, id) do
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
        GenServer.reply(from, {:error, :timeout})
        {:noreply, %{state | waiters: waiters}}
    end
  end

  # Any other message is an inbound WebSocket transport frame.
  def handle_info(message, state) do
    case WebSocket.stream(state.conn, message) do
      {:ok, conn, responses} ->
        state = %{state | conn: conn}

        case Protocol.decode_frames(state.websocket, responses, state.ref) do
          {:ok, websocket, frames} ->
            {:noreply, Enum.reduce(frames, %{state | websocket: websocket}, &dispatch/2)}

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
  def terminate(_reason, state) do
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

  # A dropped socket is a controlled end of this connection's life, not a crash:
  # fail pending callers with the clean `{:ws_closed, reason}` shape, then stop
  # under `:shutdown` so OTP doesn't emit a crash report. The owning Browser sees
  # the reason via its monitor and decides whether it's worth logging.
  defp stop_ws_closed(state, reason) do
    fail_all_pending(state, {:ws_closed, reason})
    {:stop, {:shutdown, {:ws_closed, reason}}, state}
  end

  # ── frame dispatch ──────────────────────────────────────────────────────────

  defp dispatch(frame, state) do
    case Protocol.classify(frame) do
      {:reply, id, result} -> dispatch_reply(id, result, state)
      {:event, method, params} -> dispatch_event(method, params, state)
      {:ping, data} -> pong(state, data)
      :ignore -> state
    end
  end

  defp dispatch_reply(id, result, state) do
    case Map.pop(state.pending, id) do
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

  defp dispatch_event(method, params, state) do
    state
    |> notify_waiters(params)
    |> notify_subscribers(method, params)
  end

  defp notify_waiters(state, params) do
    {matched, kept} =
      Enum.split_with(state.waiters, fn {matcher, _from, _timer} -> safe_match(matcher, params) end)

    Enum.each(matched, fn {_matcher, from, timer} ->
      cancel_timer(timer)
      GenServer.reply(from, :ok)
    end)

    %{state | waiters: kept}
  end

  defp notify_subscribers(state, method, params) do
    method_subs = Map.get(state.subscribers, method, MapSet.new())

    method_subs
    |> MapSet.union(state.all_subscribers)
    |> Enum.each(fn pid -> send(pid, {:cdp_event, self(), method, params}) end)

    state
  end

  defp safe_match(matcher, params) do
    matcher.(params)
  rescue
    _ -> false
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
          {:ok, conn} -> %{state | websocket: websocket, conn: conn}
          {:error, conn, _reason} -> %{state | conn: conn}
        end

      {:error, websocket, _reason} ->
        %{state | websocket: websocket}
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
      {:headers, ^ref, headers}, {s, _h, d} -> {s, headers, d}
      {:done, ^ref}, {s, h, _d} -> {s, h, true}
      _other, acc -> acc
    end)
  end

  # ── helpers ─────────────────────────────────────────────────────────────────

  defp fail_all_pending(state, reason) do
    Enum.each(state.pending, fn {_id, {from, _method, timer}} ->
      cancel_timer(timer)
      GenServer.reply(from, {:error, reason})
    end)

    # Reply waiters with the real failure reason (e.g. {:ws_closed, _}), not
    # {:error, :timeout} — a dropped socket must be distinguishable from a page
    # that simply never fired the awaited event.
    Enum.each(state.waiters, fn {_matcher, from, timer} ->
      cancel_timer(timer)
      GenServer.reply(from, {:error, reason})
    end)
  end

  defp pop_waiter(waiters, from) do
    case Enum.split_with(waiters, fn {_m, f, _t} -> f == from end) do
      {[waiter | _], rest} -> {waiter, rest}
      {[], rest} -> {nil, rest}
    end
  end

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
