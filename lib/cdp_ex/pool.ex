defmodule CDPEx.Pool do
  @moduledoc """
  A fixed-size pool of reusable `CDPEx.Browser` processes.

  Launching Chrome is expensive — a cold start can take several seconds on a
  constrained host, with a fresh profile each time. A pool keeps browsers warm
  and hands them out for reuse, so a per-job fetch no longer pays a launch on
  every call.

      {:ok, pool} = CDPEx.Pool.start_link(size: 2, launch_opts: [headless: true])

      CDPEx.Pool.with_page(pool, fn page ->
        {:ok, _} = CDPEx.Page.navigate(page, "https://example.com")
        CDPEx.Page.html(page)
      end)

  Browsers are launched **lazily** up to `:size` and reused thereafter.
  `checkout/2` blocks (up to `:checkout_timeout`) when every browser is busy. The
  pool is resilient: a caller that crashes while holding a browser has it returned
  automatically, and a browser that crashes is dropped and relaunched on demand —
  so `:size` self-heals. Put the pool under your supervision tree; its
  `terminate/2` stops every browser, reaping Chrome.

  Browser launches are **synchronous** — a browser is started inside the pool
  process, so while one is launching (a cold Chrome can take a few seconds) the
  pool can't serve other checkouts or checkins. A short `:checkout_timeout` is
  therefore unreliable while the pool is still growing to `:size`; once warm,
  checkouts are immediate.

  ## Options

    * `:size` — maximum number of browsers (default `1`)
    * `:launch_opts` — options passed to each `CDPEx.Browser` (see `CDPEx.Chrome`)
    * `:checkout_timeout` — ms to wait for a free browser (default `5_000`). While
      the pool is still launching browsers to `:size`, keep this above your cold
      Chrome launch time — launches are synchronous (see below)
    * `:name` — registers the pool process
  """

  use GenServer

  alias CDPEx.Browser

  @default_size 1
  @default_checkout_timeout 5_000

  defstruct [
    :size,
    :launch_opts,
    :start_fun,
    available: [],
    busy: %{},
    waiting: :queue.new(),
    count: 0
  ]

  @type t :: %__MODULE__{}

  # ── Public API ──────────────────────────────────────────────────────────────

  @doc "Starts a pool. See the moduledoc for options."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {gen_opts, pool_opts} = Keyword.split(opts, [:name])
    GenServer.start_link(__MODULE__, pool_opts, gen_opts)
  end

  @doc false
  def child_spec(opts) do
    # Derive a distinct id from :id/:name so several pools can run under one
    # supervisor without colliding on the default __MODULE__ id. terminate/2 stops
    # every browser sequentially (each takes a few seconds to reap Chrome), so give
    # the supervisor headroom over the GenServer 5s default.
    id = Keyword.get(opts, :id, Keyword.get(opts, :name, __MODULE__))
    %{id: id, start: {__MODULE__, :start_link, [opts]}, shutdown: 30_000}
  end

  @doc """
  Borrows a browser, blocking up to `timeout` ms when all are busy.

  Returns `{:ok, browser}`, `{:error, :timeout}`, or `{:error, reason}` if a
  browser had to be launched and failed. **Always** `checkin/2` it when done — or
  use `with_browser/3` / `with_page/3`, which do that for you.
  """
  @spec checkout(GenServer.server(), timeout()) :: {:ok, pid()} | {:error, term()}
  def checkout(pool, timeout \\ @default_checkout_timeout) do
    # Wait indefinitely on the outer call; the pool's own per-request timer is the
    # authoritative timeout (it removes the waiter and replies {:error, :timeout}).
    # This avoids a stale waiter when a slow launch blocks the pool past a tight
    # outer deadline. A pool that stops mid-wait surfaces as {:error, :noproc}.
    GenServer.call(pool, {:checkout, timeout}, :infinity)
  catch
    :exit, {:noproc, _} -> {:error, :noproc}
    :exit, {:normal, _} -> {:error, :noproc}
    :exit, {:shutdown, _} -> {:error, :noproc}
    :exit, {{:shutdown, _}, _} -> {:error, :noproc}
  end

  @doc "Returns a browser borrowed with `checkout/2`."
  @spec checkin(GenServer.server(), pid()) :: :ok
  def checkin(pool, browser), do: GenServer.cast(pool, {:checkin, browser})

  @doc """
  Runs `fun` with a checked-out browser, returning it afterwards (even if `fun`
  raises). Returns `fun`'s value, or `{:error, reason}` if no browser was free.
  """
  @spec with_browser(GenServer.server(), (pid() -> result), timeout()) ::
          result | {:error, term()}
        when result: var
  def with_browser(pool, fun, timeout \\ @default_checkout_timeout) when is_function(fun, 1) do
    case checkout(pool, timeout) do
      {:ok, browser} ->
        try do
          fun.(browser)
        after
          checkin(pool, browser)
        end

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Runs `fun` with a fresh page on a pooled browser, cleaning up the page and
  returning the browser afterwards. The pooled counterpart of `CDPEx.with_page/3`
  — it reuses a warm browser instead of launching one per call.

  `opts` are forwarded to `CDPEx.with_page/3` (e.g. `:prevent_alerts`); pass
  `:checkout_timeout` to bound the wait for a free browser. Returns `fun`'s value,
  or `{:error, reason}`.
  """
  @spec with_page(GenServer.server(), (CDPEx.Page.t() -> result), keyword()) ::
          result | {:error, term()}
        when result: var
  def with_page(pool, fun, opts \\ []) when is_function(fun, 1) do
    {timeout, page_opts} = Keyword.pop(opts, :checkout_timeout, @default_checkout_timeout)
    with_browser(pool, fn browser -> CDPEx.with_page(browser, fun, page_opts) end, timeout)
  end

  @doc "Stops the pool, stopping every browser (and reaping Chrome)."
  @spec stop(GenServer.server()) :: :ok
  def stop(pool), do: GenServer.stop(pool, :normal)

  # ── GenServer callbacks ─────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    # Trap exits: browsers are start_linked, so a browser crash arrives as an
    # {:EXIT, _, _} we handle (drop + relaunch on demand) rather than taking the
    # pool down, and terminate/2 runs to reap Chrome.
    Process.flag(:trap_exit, true)

    {:ok,
     %__MODULE__{
       size: Keyword.get(opts, :size, @default_size),
       launch_opts: Keyword.get(opts, :launch_opts, []),
       start_fun: Keyword.get(opts, :start_fun, &Browser.start_link/1)
     }}
  end

  @impl true
  def handle_call({:checkout, timeout}, from, state) do
    # Enqueue then dispatch: a request is served at once if there's capacity,
    # otherwise it waits in the queue for a checkin/crash to free a browser.
    timer = arm_timeout(from, timeout)
    {:noreply, dispatch(%{state | waiting: :queue.in({from, timer}, state.waiting)})}
  end

  @impl true
  def handle_cast({:checkin, browser}, state) do
    {:noreply, state |> release(browser) |> dispatch()}
  end

  @impl true
  def handle_info({:checkout_timeout, from}, state) do
    case remove_waiter(state.waiting, from) do
      {:ok, _timer, waiting} ->
        GenServer.reply(from, {:error, :timeout})
        {:noreply, %{state | waiting: waiting}}

      :error ->
        # Served between the timer firing and now — nothing to do.
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, _owner, _reason}, state) do
    # A checkout owner died without checking in — reclaim its browser.
    case find_busy_by_ref(state.busy, ref) do
      nil -> {:noreply, state}
      browser -> {:noreply, state |> release(browser) |> dispatch()}
    end
  end

  def handle_info({:EXIT, browser, _reason}, state) do
    # A pooled browser stopped/crashed. Drop it; capacity frees up, so dispatch
    # can serve a waiting caller by launching a replacement.
    {:noreply, state |> drop(browser) |> dispatch()}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    # Reply to anyone still blocked in checkout/2 first, so they get a clean
    # {:error, :noproc} without waiting on the (possibly multi-second) serial
    # browser teardown below.
    Enum.each(:queue.to_list(state.waiting), fn {from, timer} ->
      _ = cancel_timer(timer)
      GenServer.reply(from, {:error, :noproc})
    end)

    Enum.each(state.available, &safe_stop/1)
    Enum.each(Map.keys(state.busy), &safe_stop/1)
    :ok
  end

  # ── pool mechanics ──────────────────────────────────────────────────────────

  # Serve queued waiters while there is capacity (a free browser, or room to launch).
  defp dispatch(state) do
    case :queue.out(state.waiting) do
      {:empty, _} -> state
      {{:value, waiter}, rest} -> dispatch_to(state, waiter, rest)
    end
  end

  defp dispatch_to(%__MODULE__{available: [browser | rest_avail]} = state, waiter, rest) do
    %{state | available: rest_avail, waiting: rest}
    |> assign(browser, waiter)
    |> dispatch()
  end

  defp dispatch_to(%__MODULE__{count: count, size: size} = state, {from, timer}, rest)
       when count < size do
    case state.start_fun.(state.launch_opts) do
      {:ok, browser} ->
        %{state | count: count + 1, waiting: rest}
        |> assign(browser, {from, timer})
        |> dispatch()

      {:error, reason} ->
        _ = cancel_timer(timer)
        GenServer.reply(from, {:error, reason})
        dispatch(%{state | waiting: rest})
    end
  end

  # No capacity — leave the queue intact (state.waiting still holds the waiter).
  defp dispatch_to(state, _waiter, _rest), do: state

  # Mark `browser` busy for the waiter, monitor the owner (auto-checkin on its
  # death), cancel the wait timer, and reply.
  defp assign(state, browser, {from, timer}) do
    _ = cancel_timer(timer)
    owner = elem(from, 0)
    ref = Process.monitor(owner)
    GenServer.reply(from, {:ok, browser})
    %{state | busy: Map.put(state.busy, browser, {owner, ref})}
  end

  # Return a busy browser to the available set (a checkin, or an owner's death).
  defp release(state, browser) do
    case Map.pop(state.busy, browser) do
      {nil, _busy} ->
        state

      {{_owner, ref}, busy} ->
        Process.demonitor(ref, [:flush])
        # Don't return an already-dead browser (its {:EXIT} may not be processed
        # yet) to the available set, or dispatch could hand a dead pid to a waiter.
        # Drop it instead; the {:EXIT} path reconciles anything this misses.
        if Process.alive?(browser) do
          %{state | busy: busy, available: [browser | state.available]}
        else
          %{state | busy: busy, count: state.count - 1}
        end
    end
  end

  # Remove a dead browser from wherever it is and shrink the count.
  defp drop(state, browser) do
    cond do
      Map.has_key?(state.busy, browser) ->
        {{_owner, ref}, busy} = Map.pop(state.busy, browser)
        Process.demonitor(ref, [:flush])
        %{state | busy: busy, count: state.count - 1}

      browser in state.available ->
        %{state | available: List.delete(state.available, browser), count: state.count - 1}

      true ->
        state
    end
  end

  defp find_busy_by_ref(busy, ref) do
    Enum.find_value(busy, fn {browser, {_owner, r}} -> if r == ref, do: browser end)
  end

  defp remove_waiter(waiting, from) do
    case List.keytake(:queue.to_list(waiting), from, 0) do
      {{^from, timer}, rest} -> {:ok, timer, :queue.from_list(rest)}
      nil -> :error
    end
  end

  defp arm_timeout(_from, :infinity), do: nil

  defp arm_timeout(from, timeout) when is_integer(timeout) do
    Process.send_after(self(), {:checkout_timeout, from}, max(timeout, 0))
  end

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(ref), do: Process.cancel_timer(ref)

  defp safe_stop(browser) do
    if Process.alive?(browser), do: Browser.stop(browser)
    :ok
  catch
    :exit, _ -> :ok
  end
end
