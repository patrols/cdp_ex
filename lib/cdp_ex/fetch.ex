defmodule CDPEx.Fetch do
  @moduledoc """
  Per-page handler for the CDP `Fetch` domain, backing `CDPEx.Page.authenticate/4`.

  When armed on a page it enables `Fetch` with `handleAuthRequests`, then:

    * auto-continues every paused request (`Fetch.requestPaused` →
      `Fetch.continueRequest`) so navigation proceeds normally, and
    * answers authentication challenges (`Fetch.authRequired` →
      `Fetch.continueWithAuth`) with the configured credentials.

  Because `Fetch.enable` pauses **every** request, each one round-trips through
  this process — measurable overhead on resource-heavy pages. The handler is tied
  to the page's connection and stops when it goes down.

  This is an internal building block; use `CDPEx.Page.authenticate/4`.
  """

  use GenServer

  alias CDPEx.Connection

  @call_timeout 10_000
  @max_tracked_challenges 1024

  defstruct [:conn, :session_id, :username, :password, :source, :browser, attempts: %{}]

  @type t :: %__MODULE__{}

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    conn = Keyword.fetch!(opts, :conn)
    # Monitor the page connection so we stop when it goes down. The blocking arm
    # work (subscribe ×2 + Fetch.enable, up to @call_timeout) is deferred to
    # handle_continue/2 so that init/1 — and therefore the Browser GenServer that
    # called start_link — returns immediately instead of blocking the whole enable.
    Process.monitor(conn)

    {:ok,
     %__MODULE__{
       conn: conn,
       session_id: Keyword.get(opts, :session_id),
       username: Keyword.fetch!(opts, :username),
       password: Keyword.fetch!(opts, :password),
       source: Keyword.get(opts, :source, :any),
       browser: Keyword.fetch!(opts, :browser)
     }, {:continue, :arm}}
  end

  @impl true
  def handle_continue(:arm, state) do
    # Subscribe BEFORE enabling so no paused request can slip through between the
    # enable and the first event delivery. These are GenServer.calls; if `conn`
    # already died (a rare race where the Browser processed authenticate/4 just
    # ahead of the page-conn EXIT) they exit — catch it and stop with :noproc.
    Connection.subscribe(state.conn, "Fetch.requestPaused")
    Connection.subscribe(state.conn, "Fetch.authRequired")

    case Connection.call(state.conn, "Fetch.enable", %{"handleAuthRequests" => true}, @call_timeout,
           session_id: state.session_id
         ) do
      {:ok, _} ->
        # Signal the Browser we're armed so it can reply :ok to the still-waiting
        # authenticate/4 caller — preserving the "armed before return" guarantee
        # while leaving the Browser free to process other messages during the enable.
        send(state.browser, {:armed, self()})
        {:noreply, state}

      {:error, reason} ->
        # Arming failed (e.g. a CDP error). Tell the Browser so it fails the waiting
        # authenticate/4 caller, then stop quietly (:normal — a benign arm failure
        # shouldn't emit a GenServer crash report).
        send(state.browser, {:arm_failed, self(), reason})
        {:stop, :normal, state}
    end
  catch
    :exit, _ ->
      # The page connection died mid-arm (a close/authenticate race) — same quiet path.
      send(state.browser, {:arm_failed, self(), :noproc})
      {:stop, :normal, state}
  end

  @impl true
  def handle_info(
        {:cdp_event, conn, "Fetch.requestPaused", %{"requestId" => request_id}, sid},
        %__MODULE__{conn: conn, session_id: sid} = state
      ) do
    # Let every paused request proceed unchanged (no rewrite/fulfill/fail yet).
    _ = call(state, "Fetch.continueRequest", %{"requestId" => request_id})
    {:noreply, state}
  end

  def handle_info(
        {:cdp_event, conn, "Fetch.authRequired", %{"requestId" => request_id} = params, sid},
        %__MODULE__{conn: conn, session_id: sid} = state
      ) do
    {response, attempts} =
      auth_decision(state.source, state.attempts, request_id, params["authChallenge"] || %{},
        username: state.username,
        password: state.password
      )

    _ =
      call(state, "Fetch.continueWithAuth", %{
        "requestId" => request_id,
        "authChallengeResponse" => response
      })

    {:noreply, %{state | attempts: attempts}}
  end

  def handle_info({:DOWN, _ref, :process, conn, _reason}, %__MODULE__{conn: conn} = state) do
    {:stop, :normal, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    # Best-effort: the connection may already be gone (Connection.call and
    # safe_unsubscribe both tolerate that), leaving nothing to disable.
    _ = call(state, "Fetch.disable", %{})
    safe_unsubscribe(state.conn)
    :ok
  end

  @doc false
  # Decide the authChallengeResponse and the next attempts map for a challenge.
  # Pure, so the source filter + bad-credentials loop guard are unit-testable
  # without Chrome.
  @spec auth_decision(atom(), map(), String.t(), map(), keyword()) :: {map(), map()}
  def auth_decision(source_filter, attempts, request_id, challenge, creds) do
    cond do
      not source_match?(source_filter, challenge["source"]) ->
        {%{"response" => "Default"}, attempts}

      Map.get(attempts, request_id, 0) >= 1 ->
        # Already answered once; a repeat means the credentials were rejected —
        # cancel rather than loop forever.
        {%{"response" => "CancelAuth"}, Map.delete(attempts, request_id)}

      true ->
        response = %{
          "response" => "ProvideCredentials",
          "username" => Keyword.fetch!(creds, :username),
          "password" => Keyword.fetch!(creds, :password)
        }

        {response, track_attempt(attempts, request_id)}
    end
  end

  # Only the rejection path (`CancelAuth`) ever deletes an entry; a
  # successfully-answered challenge emits no same-id follow-up to prune on, so cap
  # the map to bound growth on a long-lived page that keeps meeting fresh
  # challenges. In practice (proxy creds are cached after the first success) the
  # live size is 0–1, so the cap is a safety valve; dropping entries at the cap at
  # most re-offers credentials once for a challenge still in flight.
  defp track_attempt(attempts, request_id) when map_size(attempts) >= @max_tracked_challenges,
    do: %{request_id => 1}

  defp track_attempt(attempts, request_id), do: Map.put(attempts, request_id, 1)

  defp source_match?(:any, _source), do: true
  defp source_match?(:proxy, "Proxy"), do: true
  defp source_match?(:server, "Server"), do: true
  defp source_match?(_filter, _source), do: false

  defp call(state, method, params) do
    Connection.call(state.conn, method, params, @call_timeout, session_id: state.session_id)
  end

  defp safe_unsubscribe(conn) do
    Connection.unsubscribe(conn, "Fetch.requestPaused")
    Connection.unsubscribe(conn, "Fetch.authRequired")
    :ok
  catch
    :exit, _ -> :ok
  end
end
