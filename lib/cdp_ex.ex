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

  Observability is via `:telemetry` — see `CDPEx.Telemetry` for the event taxonomy
  (launch / navigate spans, page open/close, and error events). Silent by default.

  ## Error handling

  Every operation returns `{:error, reason}` on failure; `t:error_reason/0` documents
  the reason shapes. To drive retries without hard-coding that list, classify the
  reason instead of matching it:

      case CDPEx.Page.navigate(page, url) do
        {:ok, page} ->
          {:ok, page}
        {:error, reason} ->
          if CDPEx.transient?(reason), do: retry(), else: {:error, reason}
      end

  `classify_error/1` buckets a reason as `:transient` (a fresh attempt may succeed),
  `:terminal` (it won't), or `:unknown` (payload-dependent — you decide). It tracks
  the error surface as the library evolves, so the transient/terminal decision stays
  in one place rather than being reimplemented (and re-drifting) downstream. Retries
  stay yours to bound: cap attempts, back off, and on `:transient` re-establish the
  resource (a fresh page/browser) rather than reusing a dead handle.

  > #### Status {: .info}
  >
  > Pages default to one WebSocket each (strong crash isolation); opt into
  > `sessionId` multiplexing (many pages over the one browser socket) with
  > `new_page(browser, transport: :session)`, trading isolation for fewer sockets.
  > Connection pooling, network interception, and stealth remain out of scope.
  """

  alias CDPEx.Browser
  alias CDPEx.Page
  alias CDPEx.Telemetry

  @typedoc """
  The `reason` shapes that appear in `{:error, reason}` across CDPEx.

  Error reasons are part of the public contract — pattern-match the **tagged kinds**
  (`{:cdp_error, …}`, `{:timeout, …}`, `{:ws_closed, …}`, …); their payloads (a CDP
  method, an exit status, a stderr/contents excerpt) are open and may gain detail.

  The only bare, context-free reasons are `:noproc`, the high-level `:timeout`,
  `:unknown_page`, `:already_authenticated`, and `:already_intercepting` —
  self-describing control-flow outcomes with no payload to carry, the way GenServer
  uses `:noproc`. Validation failures that *do* have offending data to surface are
  tagged instead (`{:invalid_response_body, excerpt}`, `{:invalid_pdf_data, excerpt}`,
  `{:invalid_screenshot_data, excerpt}`).

  To act on a failure without hard-coding this list, use `classify_error/1` — it
  buckets any reason as `:transient` / `:terminal` / `:unknown` and tracks this union,
  so retry logic isn't reimplemented (and re-drifted) downstream.

  Two sub-unions are machine-checked: `t:CDPEx.Connection.call_error/0` and
  `t:CDPEx.Chrome.launch_error/0` are precisely specced on `call/5` / `launch/1`, so
  Dialyzer catches a shape change in *those* at the source. The remaining members —
  the page-level tagged kinds and bare atoms — are hand-maintained (kinds such as
  `{:cdp_error, method, payload}` also wrap arbitrary CDP data), kept honest by a
  compile-time coverage test that fails if any member here lacks a `classify_error/1`
  test exemplar — so a new member can't be added without being classified.

  Two timeout shapes, by layer: the low-level `CDPEx.Connection.call/5` and
  `await_event/4` return `{:timeout, context}` (a CDP method, or `:await_event`),
  while the high-level `CDPEx.Page` `wait_for_*` functions and `CDPEx.Pool.checkout/2`
  return a bare `:timeout` ("the awaited condition didn't happen in time").

  A WebSocket frame that fails to decode is not a standalone reason: the connection
  stops on the decode failure, so callers observe it nested, as
  `{:ws_closed, {:ws_decode, _}}`.
  """
  @type error_reason ::
          CDPEx.Connection.call_error()
          | CDPEx.Chrome.launch_error()
          | {:ws_connect, term()}
          | {:ws_upgrade, term()}
          | :timeout
          | :unknown_page
          | :already_authenticated
          | :already_intercepting
          | {:timeout, :await_event}
          | {:conflict, :authenticated | :intercepting}
          | {:navigate, String.t()}
          | {:no_document_response, String.t()}
          | {:capture_failed, term()}
          | {:idle_wait_failed, term()}
          | {:selector_not_found, String.t()}
          | {:evaluate_exception, term()}
          | {:unexpected_evaluate, term()}
          | {:invalid_args, term()}
          | {:invalid_source, term()}
          | {:invalid_error_reason, term()}
          | {:invalid_transport, term()}
          | {:unsupported_transport, term()}
          | {:invalid_response_body, String.t()}
          | {:invalid_pdf_data, String.t()}
          | {:invalid_screenshot_data, String.t()}
          | {:write_failed, term()}

  @typedoc """
  The result of `classify_error/1`.

  Intentionally open: match `:transient` (or `:terminal`) explicitly and fall through
  with a catch-all rather than enumerating all three atoms, so a future bucket can be
  added without breaking exhaustive matches.
  """
  @type error_classification :: :transient | :terminal | :unknown

  @doc """
  Classifies an error `reason` as `:transient`, `:terminal`, or `:unknown`.

  `reason` is the value from any `{:error, reason}` this library returns (see
  `t:error_reason/0`). The classification answers one question — **might a fresh
  attempt succeed?** — so you drive retries from one place instead of reimplementing
  the decision (and re-drifting it) in every caller:

      case CDPEx.Page.navigate(page, url) do
        {:ok, page} ->
          {:ok, page}
        {:error, reason} ->
          case CDPEx.classify_error(reason) do
            :transient -> retry_with_fresh_page()
            _ -> {:error, reason}
          end
      end

  The buckets:

    * `:transient` — environmental or timing failures: the connection dropped or
      couldn't be established (`{:ws_closed, _}`, `{:ws_connect, _}`, `{:ws_upgrade, _}`,
      `:noproc`), a wait or call timed out (`:timeout`, `{:timeout, _}`), Chrome died
      or was slow to start (`{:chrome_exited, _, _}`, `{:debug_url_not_found, _}`,
      `{:devtools_file_malformed, _}`), or an internal capture/idle helper crashed
      (`{:capture_failed, _}`, `{:idle_wait_failed, _}`).
    * `:terminal` — deterministic outcomes: a selector didn't match, JS threw, a
      usage/validation error, or a missing Chrome binary. Retrying the same call
      yields the same error. (`:already_authenticated` / `:already_intercepting` are
      terminal for the ordinary double-call; the narrow post-timeout teardown race
      `authenticate/4` documents — where a retry can still succeed — is signalled by
      the preceding `{:timeout, _}`, which is itself `:transient`.)
    * `:unknown` — the outcome depends on a payload or timing this function does not
      crack: the `net::ERR_*` text (`{:navigate, _}`), the CDP error code
      (`{:cdp_error, _, _}`), the file-write posix reason (`{:write_failed, _}`), or
      whether a `{:no_document_response, _}` was a same-document hop or a slow miss.
      Also covers any term `CDPEx` doesn't produce. Decide the retry policy yourself.

  Retries are the caller's responsibility: bound the attempts and back off. A
  `:transient` result means **re-establish the resource** — open a fresh page/browser
  or call `CDPEx.Pool.checkout/2` again — not retry the same handle (a dead page keeps
  returning `:noproc`). The input is typed `term()` so the catch-all stays reachable;
  routing through this instead of matching `t:error_reason/0` directly trades Dialyzer
  exhaustiveness for a stable, library-maintained dispatch point.
  """
  @spec classify_error(term()) :: error_classification()
  # Transient — a fresh attempt may succeed (connection / process / launch / helper).
  def classify_error({:ws_closed, _}), do: :transient
  def classify_error({:ws_connect, _}), do: :transient
  def classify_error({:ws_upgrade, _}), do: :transient
  def classify_error(:noproc), do: :transient
  def classify_error(:timeout), do: :transient
  def classify_error({:timeout, _}), do: :transient
  def classify_error({:chrome_exited, _, _}), do: :transient
  def classify_error({:debug_url_not_found, _}), do: :transient
  def classify_error({:devtools_file_malformed, _}), do: :transient
  def classify_error({:capture_failed, _}), do: :transient
  def classify_error({:idle_wait_failed, _}), do: :transient
  # Terminal — deterministic; retrying the same call yields the same error.
  def classify_error({:chrome_not_found, _}), do: :terminal
  def classify_error({:selector_not_found, _}), do: :terminal
  def classify_error({:evaluate_exception, _}), do: :terminal
  def classify_error({:unexpected_evaluate, _}), do: :terminal
  def classify_error({:invalid_args, _}), do: :terminal
  def classify_error({:invalid_source, _}), do: :terminal
  def classify_error({:invalid_error_reason, _}), do: :terminal
  def classify_error({:invalid_transport, _}), do: :terminal
  def classify_error({:unsupported_transport, _}), do: :terminal
  def classify_error({:invalid_response_body, _}), do: :terminal
  def classify_error({:invalid_pdf_data, _}), do: :terminal
  def classify_error({:invalid_screenshot_data, _}), do: :terminal
  def classify_error({:conflict, _}), do: :terminal
  def classify_error(:unknown_page), do: :terminal
  def classify_error(:already_authenticated), do: :terminal
  def classify_error(:already_intercepting), do: :terminal
  # Ambiguous — :unknown until the caller (or a future refinement) inspects the payload
  # or timing: the net::ERR_* text, the CDP error code, the file-write posix reason, or
  # whether a no-document navigation was a same-document hop vs a slow miss. Explicit
  # (not the catch-all) so they read as decisions and the coverage test holds them.
  def classify_error({:navigate, _}), do: :unknown
  def classify_error({:cdp_error, _, _}), do: :unknown
  def classify_error({:write_failed, _}), do: :unknown
  def classify_error({:no_document_response, _}), do: :unknown
  # Anything else — a reason CDPEx doesn't produce, or a future shape.
  def classify_error(_other), do: :unknown

  @doc """
  Convenience over `classify_error/1`: `true` only when the error is `:transient`.

  Conservative by design — `:unknown` is **not** transient, so an unrecognized or
  payload-dependent error won't be auto-retried. Match `classify_error/1` directly
  when you want to treat `:unknown` specially, and see its note on bounded,
  resource-re-establishing retries — this classifies, it does not retry.
  """
  @spec transient?(term()) :: boolean()
  def transient?(reason), do: classify_error(reason) == :transient

  @doc """
  Launches a headless Chrome browser and returns its process pid.

  Accepts the launch options documented in `CDPEx.Chrome` (e.g. `:headless`,
  `:chrome_binary`, `:extra_args`, `:window_size`, `:launch_timeout`). On slow
  cold-start hosts (e.g. headless Chrome in a constrained container) raise
  `:launch_timeout` — it is a ceiling, not a fixed wait. For long-lived use, prefer
  putting `CDPEx.Browser` under your own supervisor with a `:shutdown` timeout.
  """
  @spec launch(keyword()) :: GenServer.on_start()
  def launch(opts \\ []) do
    Telemetry.span(:launch, %{}, fn ->
      result = Browser.start_link(opts)
      {result, launch_metadata(result)}
    end)
  end

  # Launch span :stop metadata: empty on success, {error: reason} on failure — so a
  # consumer can tell a failed launch from a successful one (mirrors navigate's span).
  defp launch_metadata({:ok, _pid}), do: %{}
  defp launch_metadata({:error, reason}), do: %{error: reason}
  defp launch_metadata(:ignore), do: %{error: :ignore}

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

  With launch options, the throwaway browser is linked but **contained**: if it
  crashes during the call (e.g. its connection drops) `with_page` returns
  `{:error, reason}` instead of letting the crash propagate to the caller. To do
  that it briefly traps exits in the calling process for the duration of the call.
  Only the browser's own `{:EXIT, _, _}` is drained — a *foreign* process linked
  to the caller that exits during this window has its exit delivered as a message
  left in the caller's mailbox, so a caller that links other processes and relies
  on un-trapped exit propagation should pass a pre-launched browser pid instead.
  On slow cold-start hosts, raise `:launch_timeout` (a ceiling, not a fixed wait).

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
        # launch/1 links `browser` to us. Trap exits for the duration of this call
        # so a browser crash (e.g. its connection dropping mid-call) arrives as a
        # message — `fun`'s own {:error, _} returns first and is never masked —
        # instead of a link exit that would kill the caller, breaking with_page's
        # resource-safe contract. We keep the link (not just a monitor) so that if
        # the *caller* dies, the browser is still reaped via Browser.terminate/2.
        prev_trap = Process.flag(:trap_exit, true)

        try do
          try do
            with_page(browser, fun, opts)
          after
            safe(fn -> stop(browser) end)
          end
        after
          # Drain the browser's queued {:EXIT, browser, _} (from its crash, or from
          # our own stop/1) so it can't surface to the caller once we restore the
          # prior trap_exit flag. A foreign linked process's EXIT is left as-is.
          drain_exit(browser)
          Process.flag(:trap_exit, prev_trap)
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

  # Remove a single queued {:EXIT, browser, _} (delivered as a message because the
  # throwaway-browser `with_page/3` clause traps exits) so it can't leak to the
  # caller after the prior trap_exit flag is restored. At most one can exist — a
  # process exits once.
  defp drain_exit(browser) do
    receive do
      {:EXIT, ^browser, _reason} -> :ok
    after
      0 -> :ok
    end
  end
end
