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
  (launch / navigate spans, page open/close, `with_page/3` deadlines, and error
  events). Silent by default.

  ## Error handling

  Every operation returns `{:error, reason}` on failure; `t:error_reason/0` documents
  the reason shapes. That includes runtime failures — Chrome that can't be spawned, a
  browser, page or pool process that is gone or stops mid-call, a call it can't serve
  in time — which come back as values, never as a raise or an exit in the caller.
  The guarantee covers return values, not links: a browser from `launch/1` or
  `connect/2` stays linked to the process that started it, so if Chrome dies, a starter
  that doesn't trap exits still receives the exit signal (run it under a supervisor;
  `with_page/3` with launch options contains this for its throwaway browser).
  Invalid arguments (a bad `:deadline` or `:wait`, a wrong type) still raise; that is a
  bug in the calling code. So does anything `with_page/3`'s own `fun` raises, throws or
  exits with. To drive retries without hard-coding that list, classify the
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
  > Stealth / anti-fingerprinting presets remain out of scope.
  """

  alias CDPEx.Browser
  alias CDPEx.Chrome
  alias CDPEx.Connect
  alias CDPEx.Page
  alias CDPEx.ProcessLabel
  alias CDPEx.Telemetry

  @typedoc """
  The `reason` shapes that appear in `{:error, reason}` across CDPEx.

  Error reasons are part of the public contract — pattern-match the **tagged kinds**
  (`{:cdp_error, …}`, `{:timeout, …}`, `{:ws_closed, …}`, …); their payloads (a CDP
  method, an exit status, a stderr/contents excerpt) are open and may gain detail.

  The only bare, context-free reasons are `:noproc`, the high-level `:timeout`,
  `:deadline_exceeded` (`with_page/3`'s `:deadline`), `:unknown_page`,
  `:already_authenticated`, and `:already_intercepting` —
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
  test exemplar — so a member can't be added to this type without being classified.
  That guard is one-directional (type → classified): the reverse — an error a producer
  returns but never adds here — still relies on review, and such a stray reason would
  fall through `classify_error/1` to `:unknown`.

  Two timeout shapes, by layer: the low-level `CDPEx.Connection.call/5`,
  `await_event/4` and `subscribe/4` and the `CDPEx.Browser` requests return
  `{:timeout, context}` (a CDP method, `:await_event`, `:subscribe`, `:new_page`,
  `:close_page`, or `:authenticate`), while the high-level `CDPEx.Page` `wait_for_*` functions and `CDPEx.Pool.checkout/2`
  return a bare `:timeout` ("the awaited condition didn't happen in time").

  A WebSocket frame that fails to decode is not a standalone reason: the connection
  stops on the decode failure, so callers observe it nested, as
  `{:ws_closed, {:ws_decode, _}}`.
  """
  @type error_reason ::
          CDPEx.Connection.call_error()
          | Chrome.launch_error()
          | {:ws_connect, term()}
          | {:ws_upgrade, term()}
          | :timeout
          | :deadline_exceeded
          | :unknown_page
          | :already_authenticated
          | :already_intercepting
          | {:timeout, :await_event | :new_page | :close_page | :authenticate | :subscribe}
          | {:conflict, :authenticated | :intercepting}
          | {:navigate, String.t()}
          | {:no_document_response, String.t()}
          | {:connect_discovery_failed, term()}
          | {:capture_failed, term()}
          | {:idle_wait_failed, term()}
          | {:selector_not_found, String.t()}
          | {:text_not_found, String.t()}
          | {:not_clickable, String.t()}
          | {:unknown_key, String.t()}
          | {:evaluate_exception, term()}
          | {:unserializable_value, String.t()}
          | {:unexpected_evaluate, term()}
          | {:invalid_args, term()}
          | {:invalid_source, term()}
          | {:invalid_error_reason, term()}
          | {:invalid_transport, term()}
          | {:invalid_proxy, term()}
          | {:unsupported_transport, term()}
          | {:unsupported_with_connect, term()}
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
      `:noproc`), a `:session` page's target closed or detached (`{:session_closed, _}`,
      the session-transport counterpart of a dedicated page's `:noproc`), a wait or call
      timed out (`:timeout`, `{:timeout, _}`, `:deadline_exceeded`), Chrome died
      or was slow to start (`{:chrome_exited, _, _}`, `{:debug_url_not_found, _}`,
      `{:devtools_file_malformed, _}`), an internal capture/idle helper crashed
      (`{:capture_failed, _}`, `{:idle_wait_failed, _}`), or a navigation hit a
      connection/network-layer `net::ERR_*` (e.g. `{:navigate, "net::ERR_CONNECTION_REFUSED"}`).
    * `:terminal` — deterministic outcomes: a selector or text didn't match, JS threw, a
      usage/validation error, or a missing Chrome binary. Retrying the same call
      yields the same error. (`:already_authenticated` / `:already_intercepting` are
      terminal for the ordinary double-call; the narrow post-timeout teardown race
      `authenticate/4` documents — where a retry can still succeed — is signalled by
      the preceding `{:timeout, _}`, which is itself `:transient`.)
    * `:unknown` — the outcome depends on a payload or timing this function does not
      crack: an ambiguous navigation `net::ERR_*` (DNS `ERR_NAME_NOT_RESOLVED`,
      `ERR_ABORTED`, `ERR_BLOCKED_BY_*` — unlike the connection-layer codes above), the
      CDP error code (`{:cdp_error, _, _}`), the file-write posix reason
      (`{:write_failed, _}`), why Chrome couldn't be started at all
      (`{:launch_failed, _}` — an unwritable profile dir or a refused spawn: `:emfile`
      may clear, `:eacces` won't), whether a `{:no_document_response, _}` was a
      same-document hop or a slow miss, or a `connect/2` endpoint-discovery failure
      (`{:connect_discovery_failed, _}` — a transient network blip and a permanently
      bad endpoint are indistinguishable here). Also covers any term `CDPEx` doesn't
      produce. Decide the retry policy yourself.

  Retries are the caller's responsibility: bound the attempts and back off. A
  `:transient` result means **re-establish the resource** — open a fresh page/browser
  or call `CDPEx.Pool.checkout/2` again — not retry the same handle (a dead page keeps
  returning `:noproc`, or `{:session_closed, _}` for a `:session` page). Some
  `:transient` reasons are still a judgment call for your environment — retrying a `:timeout` / `net::ERR_TIMED_OUT` multiplies wall-time and
  browser memory, so a resource-constrained caller may reasonably treat timeouts as
  terminal. The input is typed `term()` so the catch-all stays reachable;
  routing through this instead of matching `t:error_reason/0` directly trades Dialyzer
  exhaustiveness for a stable, library-maintained dispatch point.
  """
  @spec classify_error(term()) :: error_classification()
  # Transient — a fresh attempt may succeed (connection / process / launch / helper).
  def classify_error({:ws_closed, _}), do: :transient
  def classify_error({:ws_connect, _}), do: :transient
  def classify_error({:ws_upgrade, _}), do: :transient
  def classify_error(:noproc), do: :transient
  def classify_error({:session_closed, _}), do: :transient
  def classify_error(:timeout), do: :transient
  def classify_error({:timeout, _}), do: :transient
  def classify_error(:deadline_exceeded), do: :transient
  def classify_error({:chrome_exited, _, _}), do: :transient
  def classify_error({:debug_url_not_found, _}), do: :transient
  def classify_error({:devtools_file_malformed, _}), do: :transient
  def classify_error({:capture_failed, _}), do: :transient
  def classify_error({:idle_wait_failed, _}), do: :transient
  # Terminal — deterministic; retrying the same call yields the same error.
  def classify_error({:chrome_not_found, _}), do: :terminal
  def classify_error({:selector_not_found, _}), do: :terminal
  def classify_error({:text_not_found, _}), do: :terminal
  def classify_error({:not_clickable, _}), do: :terminal
  def classify_error({:unknown_key, _}), do: :terminal
  def classify_error({:evaluate_exception, _}), do: :terminal
  def classify_error({:unserializable_value, _}), do: :terminal
  def classify_error({:unexpected_evaluate, _}), do: :terminal
  def classify_error({:invalid_args, _}), do: :terminal
  def classify_error({:invalid_source, _}), do: :terminal
  def classify_error({:invalid_error_reason, _}), do: :terminal
  def classify_error({:invalid_transport, _}), do: :terminal
  def classify_error({:invalid_proxy, _}), do: :terminal
  def classify_error({:unsupported_transport, _}), do: :terminal
  def classify_error({:unsupported_with_connect, _}), do: :terminal
  def classify_error({:invalid_response_body, _}), do: :terminal
  def classify_error({:invalid_pdf_data, _}), do: :terminal
  def classify_error({:invalid_screenshot_data, _}), do: :terminal
  def classify_error({:conflict, _}), do: :terminal
  def classify_error(:unknown_page), do: :terminal
  def classify_error(:already_authenticated), do: :terminal
  def classify_error(:already_intercepting), do: :terminal
  # A navigation failure carries Chrome's net::ERR_* text: connection/network-layer
  # codes are transient (a fresh attempt may succeed); everything else stays :unknown
  # (see @transient_net_errors). A non-string payload can't be inspected -> :unknown.
  def classify_error({:navigate, error_text}) when is_binary(error_text) do
    if transient_net_error?(error_text), do: :transient, else: :unknown
  end

  # Ambiguous — :unknown until the caller (or a future refinement) inspects the payload
  # or timing: a non-string navigate reason, an ambiguous net::ERR_* (DNS / blocked /
  # aborted), the CDP error code, the file-write posix reason, or whether a no-document
  # navigation was a same-document hop vs a slow miss. Explicit (not the catch-all) so
  # they read as decisions and the coverage test holds them.
  def classify_error({:navigate, _}), do: :unknown
  def classify_error({:cdp_error, _, _}), do: :unknown
  def classify_error({:write_failed, _}), do: :unknown
  def classify_error({:launch_failed, _}), do: :unknown
  def classify_error({:no_document_response, _}), do: :unknown
  def classify_error({:connect_discovery_failed, _}), do: :unknown
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

  # Connection/network-layer net::ERR_* codes whose retry outcome is unambiguous: a
  # fresh attempt may succeed. These are site-independent Chromium semantics, not
  # site-specific guesses. Genuinely ambiguous codes (DNS ERR_NAME_NOT_RESOLVED,
  # ERR_ABORTED, ERR_BLOCKED_BY_*, ERR_TOO_MANY_REDIRECTS) are deliberately left
  # :unknown for the caller to decide.
  @transient_net_errors MapSet.new(~w(
                            ERR_CONNECTION_REFUSED
                            ERR_CONNECTION_RESET
                            ERR_CONNECTION_CLOSED
                            ERR_CONNECTION_ABORTED
                            ERR_CONNECTION_TIMED_OUT
                            ERR_TIMED_OUT
                            ERR_NETWORK_CHANGED
                            ERR_INTERNET_DISCONNECTED
                            ERR_ADDRESS_UNREACHABLE
                            ERR_SOCKET_NOT_CONNECTED
                          ))

  # Exact-token match on the code after the "net::" prefix (Chrome's navigate errorText is
  # the bare code) — not a substring scan, so a future allowlist entry can't silently flip
  # an ambiguous code that merely contains it. A non-"net::" / suffixed text is :unknown.
  defp transient_net_error?("net::" <> code), do: MapSet.member?(@transient_net_errors, code)
  defp transient_net_error?(_error_text), do: false

  @doc """
  Launches a headless Chrome browser and returns `{:ok, pid}`, or `{:error, reason}`
  (e.g. `{:chrome_not_found, path}`, `{:launch_failed, _}`, `{:debug_url_not_found, _}`).

  The browser is linked to the caller, but a failed launch returns its error without
  exiting the caller, whether or not it traps exits.

  Accepts the launch options documented in `CDPEx.Chrome` (e.g. `:headless`,
  `:chrome_binary`, `:extra_args`, `:window_size`, `:launch_timeout`). On slow
  cold-start hosts (e.g. headless Chrome in a constrained container) raise
  `:launch_timeout` — it is a ceiling, not a fixed wait. For long-lived use, prefer
  putting `CDPEx.Browser` under your own supervisor with a `:shutdown` timeout.

  ## Proxy

  Pass `:proxy` to route the browser through a proxy — a URL or a keyword list:

      CDPEx.launch(proxy: "http://user:pass@host:8080")
      CDPEx.launch(proxy: [server: "host:8080", username: "u", password: "p"])

  It sets Chrome's `--proxy-server` and, when credentials are given, **automatically
  answers the proxy auth challenge on each page** — so you just `new_page/2` and
  `CDPEx.Page.navigate/3`, no manual `CDPEx.Page.authenticate/4`. See `CDPEx.Proxy` for
  the accepted forms (the keyword form avoids percent-encoding special-character
  passwords).

  A credentialed proxy requires the default `:dedicated` transport: `new_page(transport:
  :session)` on such a browser returns `{:error, {:unsupported_transport, :session}}`,
  and an auto-armed page can't also use `enable_request_interception/2` (both drive the
  `Fetch` domain). A malformed `:proxy` — or combining it with a full `:args` override —
  fails the launch with `{:error, {:invalid_proxy, _}}` (`:proxy` appends to `:extra_args`,
  which an `:args` override discards, so the two are mutually exclusive; use one). Don't
  set `--proxy-server` in `:extra_args` yourself when using `:proxy`.
  """
  @spec launch(keyword()) :: GenServer.on_start()
  def launch(opts \\ []) do
    # A caller bug raises here, outside the span, rather than counting as a launch exception.
    Browser.validate_launch_opts!(opts)

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

  @doc """
  Connects to an already-running Chrome instead of launching one.

  `endpoint` is either a `ws://`/`wss://` browser WebSocket URL (used directly) or
  an `http://`/`https://` base URL (the browser socket is discovered via
  `GET /json/version`, with the host/port taken from `endpoint`). Returns the same
  handle as `launch/1`, so `new_page/2`, `with_page/3`, `close_page/2`, and
  `stop/1` all work — but `stop/1` only closes the pages cdp_ex opened and drops
  the socket; it never kills the remote Chrome or touches pre-existing tabs.

  > #### http(s) discovery is IP/localhost only {: .warning}
  >
  > Chrome's DevTools HTTP endpoint rejects `/json/version` with **403** when the
  > `Host` header is a non-IP, non-`localhost` name (DNS-rebinding protection), so
  > the `http(s)://` discovery form works only for IP / `localhost` endpoints (a 403
  > surfaces as `{:error, {:connect_discovery_failed, {:http_status, 403}}}`). For a
  > **named** remote/sidecar/cloud host, pass the `ws(s)://` browser URL directly
  > (or launch that Chrome with a permissive `--remote-allow-origins`/host).

  Pages default to `:session` transport; `transport: :dedicated` returns
  `{:error, {:unsupported_transport, :dedicated}}` (not yet supported over a
  connected browser).

  Options: `:insecure` (skip `wss://` cert verification, default `false`),
  `:cacertfile` / `:cacerts` (custom CA for `wss://`), `:discovery_timeout` (ceiling
  in ms for the whole `http(s)://` `/json/version` exchange — TCP connect, recv, and
  body — default `5_000`; raise it for a slow remote endpoint, or pass `:infinity` for
  no limit, which lets an endpoint that never answers hang the caller; `nil` means the
  default, and any other value that isn't an integer in `0..4_294_967_295` raises
  `ArgumentError`), `:name` (register the process).
  """
  @spec connect(String.t(), keyword()) :: GenServer.on_start()
  def connect(endpoint, opts \\ []) when is_binary(endpoint) do
    {disc_timeout, opts} = Keyword.pop(opts, :discovery_timeout)
    disc_opts = discovery_opts(disc_timeout)

    Telemetry.span(:connect, %{}, fn ->
      {tls_opts, opts} = Keyword.split(opts, [:insecure, :cacertfile, :cacerts])

      result =
        case Connect.resolve(endpoint, tls_opts, disc_opts) do
          {:ok, ws_url} -> Browser.start_link([connect: ws_url, conn_opts: tls_opts] ++ opts)
          {:error, _} = error -> error
        end

      {result, launch_metadata(result)}
    end)
  end

  defp discovery_opts(nil), do: []

  defp discovery_opts(timeout) do
    if valid_discovery_timeout?(timeout), do: [timeout: timeout], else: invalid_discovery!(timeout)
  end

  defp valid_discovery_timeout?(timeout),
    do: timeout == :infinity or (is_integer(timeout) and timeout in 0..4_294_967_295)

  @spec invalid_discovery!(term()) :: no_return()
  defp invalid_discovery!(other) do
    raise ArgumentError,
          "invalid :discovery_timeout #{inspect(other)} (expected integer ms in 0..4_294_967_295 or :infinity)"
  end

  @doc """
  Stops a browser started with `launch/1` (kills Chrome) or `connect/2` (closes the
  pages it opened, leaves Chrome running). `:ok` if the browser is already gone.
  """
  @spec stop(pid()) :: :ok
  def stop(browser), do: Browser.stop(browser)

  @doc "Opens a new page. See `CDPEx.Browser.new_page/2` for options."
  @spec new_page(pid(), keyword()) :: {:ok, Page.t()} | {:error, term()}
  def new_page(browser, opts \\ []), do: Browser.new_page(browser, opts)

  @doc """
  Closes a page opened with `new_page/2`.

  Returns `{:error, :unknown_page}` if `page` was not opened on `browser`, and
  `{:error, :noproc}` if `browser` is gone (see `CDPEx.Browser.close_page/2`).
  """
  @spec close_page(pid(), Page.t()) ::
          :ok | {:error, :unknown_page | :noproc | {:timeout, :close_page}}
  def close_page(browser, page), do: Browser.close_page(browser, page)

  @doc """
  Runs `fun` with a fresh page, guaranteeing the page (and, when given launch
  options, the browser) is cleaned up afterwards — even if `fun` raises.

  Pass an existing browser pid to reuse it, or a keyword list of launch options
  to spin up a throwaway browser for the duration of the call. A `[connect:
  endpoint]` list attaches to an already-running Chrome instead of launching one
  (see `connect/2`); teardown then closes only the pages it opened and never reaps
  that Chrome. Returns whatever `fun` returns, or `{:error, reason}` if the
  page/browser could not be created.

  Failures in `with_page`'s own work (the launch or connect, opening the page, a
  browser that is gone or dies under it, the teardown) come back as
  `{:error, reason}`, never as a raise or an exit. A raise, throw or exit from `fun`
  itself propagates unchanged: that is the caller's code.

  With launch options, the throwaway browser is linked but **contained**: if it
  fails to start, or crashes during the call (e.g. its connection drops),
  `with_page` returns `{:error, reason}` instead of letting the exit propagate to
  the caller. To do that it briefly traps exits in the calling process for the
  duration of the call, launch included, and the trap is invisible afterwards: the
  browser's own `{:EXIT, _, _}` is drained, and a *foreign* exit signal that arrives
  during the call (a linked process crashing, or an `exit/2` such as Oban's job
  timeout) takes effect when `with_page` returns or unwinds. A caller that doesn't
  trap exits is then terminated with that signal's reason (a `:normal` one is
  dropped); a caller that traps exits finds it in its mailbox, as usual. Until the
  call ends, though, such a signal doesn't interrupt `fun`, so a caller with a time
  budget (e.g. an Oban worker's `timeout/1`) should also pass `:deadline`, which
  bounds the call itself.
  On slow cold-start hosts, raise `:launch_timeout` (a ceiling, not a fixed wait).

  `opts` go to `new_page/2`, except `:deadline`.

  ## Deadline

  Each page operation has its own timeout, but they stack: a navigation, a few
  selector waits and some retries can hold a browser for minutes. Pass `deadline: ms`
  (a positive integer) to bound the whole call. The clock starts when `with_page` is
  called, so a launch counts against it.

  The rule, by the monotonic clock: the call is **exceeded iff `fun` had not returned
  by the deadline** (or never started). Then `with_page` returns
  `{:error, :deadline_exceeded}` however `fun` came back — a value, an error tuple, or
  a raise/exit caused by the teardown. A `new_page/2` error comes back as itself,
  late or not (the teardown waits for `new_page/2` to return); a page that only
  arrives after the deadline means `fun` is not started. If `fun` returned in time,
  its result or raise comes back untouched: the deadline stops there, and closing the
  page or stopping a throwaway browser afterwards runs on their own timeouts. Without
  a deadline nothing changes.

  `fun` still runs in the calling process (`self()`, the process dictionary, Logger
  metadata and links behave as without a deadline). A watchdog process enforces the
  deadline by tearing down the browser resource underneath it: a throwaway browser
  (launch options or `connect:`) is stopped, reaping a launched Chrome; with a browser
  pid, only the page `with_page` opened is closed and the browser stays yours (a
  page `fun` opens itself is not released). The browser call `fun` is blocked in then
  fails fast and `fun` unwinds. Work in `fun` that doesn't touch the browser — a
  sleep, a computation — runs on until its next browser call, so the bound is "the
  browser is released at the deadline", not "`fun` is preempted".

  Some stages can't be interrupted and are bounded differently:

    * **Launch** — the browser doesn't exist yet, so `:launch_timeout` is capped at the
      deadline when the deadline is smaller or equal (default `15_000`), and so is
      connect-mode's `:discovery_timeout` (default `5_000`, and a `nil` or `:infinity` is
      capped too). An invalid value is not capped: a non-integer `:launch_timeout`
      raises `ArgumentError` like any invalid launch option, and so does a
      `:discovery_timeout` that `connect/2` rejects. The WebSocket connect and
      upgrade after them (normally milliseconds) keep their own timeouts. A start whose
      capped timeout runs out at or after the deadline returns
      `{:error, :deadline_exceeded}`, with its own error in the telemetry event's
      `:launch_error`; any other start failure comes back as itself.
    * **`new_page/2`** — the browser serves it as one call (target creation, bootstrap,
      a proxy's auth arm), so a deadline that fires mid-way takes effect when it
      returns; `fun` is then not started. A start that returns after the deadline
      skips `new_page/2` altogether.
    * **Closing the page on a browser pid** goes through the Browser, so on a shared or
      pooled browser it queues behind whatever the Browser is serving (another
      caller's `new_page/2`). If `close_page/2`'s own 15s timeout runs out first, the
      page stays open and the call in `fun` runs to its own timeout.

  With a throwaway browser the teardown's `{:EXIT, browser, :normal}` arrives while
  `fun` may still be running (the call traps exits, as for a browser crash); it is
  drained before `with_page` returns, but a catch-all `receive` in `fun` can take it.

  If the caller dies mid-call, a throwaway browser is reaped through its link as
  before, and on a browser pid the watchdog closes the page — once `new_page/2` has
  returned it; a caller that dies while `new_page/2` is in flight leaves that page
  open, as without a deadline.

  An invalid `:deadline` (not an integer in `1..4_294_967_295`) raises
  `ArgumentError`. An exceeded deadline emits
  `[:cdp_ex, :with_page, :deadline_exceeded]` (see `CDPEx.Telemetry`).

      # against an existing browser
      CDPEx.with_page(browser, fn page ->
        {:ok, _} = CDPEx.Page.navigate(page, "https://example.com")
        CDPEx.Page.html(page)
      end)

      # throwaway browser + page
      CDPEx.with_page([headless: true], &CDPEx.Page.html/1)

      # against an existing Chrome (discovered via /json/version)
      CDPEx.with_page([connect: "http://localhost:9222"], &CDPEx.Page.html/1)

      # the whole call, launch included, within 20s
      CDPEx.with_page([], &CDPEx.Page.html/1, deadline: 20_000)
  """
  @spec with_page(pid() | keyword(), (Page.t() -> result), keyword()) ::
          result | {:error, term()}
        when result: var
  def with_page(browser_or_opts, fun, opts \\ [])

  def with_page(browser, fun, opts) when is_pid(browser) and is_function(fun, 1) do
    case pop_deadline(opts) do
      {nil, opts} ->
        run_page(browser, fun, opts, nil)

      {deadline, opts} ->
        deadline_at = now_ms() + deadline

        guard_deadline(deadline, deadline_at, {:close_page, browser}, fn watch ->
          run_page(browser, fun, opts, watch)
        end)
    end
  end

  def with_page(launch_opts, fun, opts) when is_list(launch_opts) and is_function(fun, 1) do
    if Keyword.has_key?(launch_opts, :deadline) do
      raise ArgumentError,
            ":deadline goes in with_page/3's third argument, not the launch options"
    end

    case pop_deadline(opts) do
      {nil, opts} ->
        with_throwaway(
          launch_opts,
          fn browser -> run_page(browser, fun, opts, nil) end,
          &{:error, &1}
        )

      {deadline, opts} ->
        with_throwaway_deadline(launch_opts, fun, opts, deadline)
    end
  end

  defp with_throwaway_deadline(launch_opts, fun, opts, deadline) do
    deadline_at = now_ms() + deadline
    launch_opts = cap_start_timeout(launch_opts, deadline)

    with_throwaway(
      launch_opts,
      fn browser ->
        guard_deadline(deadline, deadline_at, {:stop, browser}, fn watch ->
          run_page(browser, fun, opts, watch)
        end)
      end,
      &start_error(&1, deadline, deadline_at)
    )
  end

  # Only a timeout the cap can cause is the deadline's; a rejected upgrade or a missing
  # binary must not come back as a transient :deadline_exceeded and be retried.
  defp start_error(reason, deadline, deadline_at) do
    if start_timeout?(reason) and now_ms() >= deadline_at do
      deadline_exceeded(%{deadline: deadline, outcome: :not_started, launch_error: reason})
    else
      {:error, reason}
    end
  end

  defp start_timeout?({:debug_url_not_found, _}), do: true
  defp start_timeout?({:devtools_file_malformed, _}), do: true
  defp start_timeout?({:connect_discovery_failed, :discovery_timeout}), do: true
  defp start_timeout?(_reason), do: false

  defp run_page(browser, fun, opts, nil), do: open_and_run(browser, fun, opts, nil)

  # A start can return past the deadline (its WebSocket connect isn't capped); don't
  # spend an uninterruptible new_page on an already-decided call.
  defp run_page(browser, fun, opts, {_watchdog, ref, deadline_at} = watch) do
    if now_ms() >= deadline_at do
      {ref, :expired}
    else
      open_and_run(browser, fun, opts, watch)
    end
  end

  defp open_and_run(browser, fun, opts, watch) do
    case new_page(browser, opts) do
      {:ok, page} ->
        try do
          run_fun(fun, page, watch)
        after
          safe(fn -> close_page(browser, page) end)
        end

      {:error, _} = error ->
        error
    end
  end

  defp run_fun(fun, page, nil), do: fun.(page)

  defp run_fun(fun, page, {watchdog, ref, deadline_at}) do
    send(watchdog, {:page, ref, page})

    # new_page can't be interrupted, so it may return after the deadline; don't start
    # `fun` on a page that is already being torn down.
    if now_ms() >= deadline_at do
      {ref, :expired}
    else
      outcome =
        try do
          {:ok, fun.(page)}
        catch
          kind, reason -> {kind, reason, __STACKTRACE__}
        end

      # Before run_page's close_page, which can queue behind other callers' new_page.
      finished_at = now_ms()
      stop_watchdog(watchdog, ref)
      {ref, :finished, finished_at, outcome}
    end
  end

  defp with_throwaway(launch_opts, body, on_start_error) do
    # `[connect: endpoint]` attaches to a running Chrome instead of launching one;
    # the resource-safe trap/stop/drain machinery below is identical (stop/1 on a
    # connected browser closes only the pages we opened — it never kills Chrome).
    start =
      case Keyword.pop(launch_opts, :connect) do
        {nil, _} -> fn -> launch(launch_opts) end
        {endpoint, rest} -> fn -> connect(endpoint, rest) end
      end

    # Trap from before the launch so a failed init doesn't kill the caller; keep the
    # link so caller death reaps the browser.
    prev_trap = Process.flag(:trap_exit, true)

    started =
      try do
        start.()
      catch
        kind, reason ->
          restore_trap(prev_trap, nil)
          :erlang.raise(kind, reason, __STACKTRACE__)
      end

    case started do
      {:ok, browser} ->
        try do
          try do
            body.(browser)
          after
            safe(fn -> stop(browser) end)
          end
        after
          # Drain the browser's queued {:EXIT, browser, _} (from its crash, or from
          # our own stop/1) so it can't surface to the caller once we restore the
          # prior trap_exit flag. Foreign EXITs are handled by restore_trap/2.
          drain_exit(browser)
          restore_trap(prev_trap, browser)
        end

      {:error, reason} ->
        try do
          on_start_error.(reason)
        after
          restore_trap(prev_trap, nil)
        end
    end
  end

  # Undo the trap so the caller can't tell it happened. A trapping caller expects
  # EXIT messages, so they stay queued. A non-trapping one would have been killed
  # by a foreign non-:normal exit signal (e.g. Oban's job timeout, sent with
  # exit/2): re-send it to self as a signal, so the caller dies with that reason
  # even mid-raise. Its :normal ones would have been ignored, so they are dropped.
  # `browser` (nil when the start failed, which unlinks first) is never foreign: a
  # crash of it was already returned as a value, so an EXIT from it that
  # drain_exit/1's `after 0` missed is dropped too, whatever ERTS signal order did.
  defp restore_trap(true, _browser), do: Process.flag(:trap_exit, true)

  defp restore_trap(false, browser) do
    Process.flag(:trap_exit, false)
    redeliver_exits(browser)
  end

  defp redeliver_exits(browser) do
    receive do
      {:EXIT, ^browser, _} when is_pid(browser) -> redeliver_exits(browser)
      {:EXIT, from, :normal} when is_pid(from) or is_port(from) -> redeliver_exits(browser)
      {:EXIT, from, reason} when is_pid(from) or is_port(from) -> Process.exit(self(), reason)
    after
      0 -> :ok
    end
  end

  defp pop_deadline(opts) do
    case Keyword.pop(opts, :deadline) do
      {nil, _} = absent ->
        absent

      # The upper bound is `receive ... after`'s limit; past it the watchdog would crash.
      {deadline, _} = popped when is_integer(deadline) and deadline in 1..4_294_967_295 ->
        popped

      {other, _} ->
        raise ArgumentError,
              "invalid :deadline #{inspect(other)} (expected integer ms in 1..4_294_967_295)"
    end
  end

  # There is no browser for the watchdog to tear down until the start returns.
  defp cap_start_timeout(launch_opts, deadline) do
    {key, default} =
      if Keyword.get(launch_opts, :connect) do
        {:discovery_timeout, Connect.default_discovery_timeout()}
      else
        {:launch_timeout, Chrome.default_launch_timeout()}
      end

    # An invalid value is left for launch/1 or connect/2 to reject, as it is without a
    # deadline. A nil or :infinity :discovery_timeout is valid (default / no limit), so
    # it is capped; for :launch_timeout both are invalid, and only :discovery_timeout
    # has an upper bound.
    current = Keyword.get(launch_opts, key, default)

    if cappable?(key, current) and not (is_integer(current) and deadline > current) do
      Keyword.put(launch_opts, key, deadline)
    else
      launch_opts
    end
  end

  defp cappable?(:launch_timeout, current), do: is_integer(current)

  defp cappable?(:discovery_timeout, current),
    do: is_nil(current) or valid_discovery_timeout?(current)

  # The verdict is the clock's, not the watchdog's: it only fires at or after
  # `deadline_at`, so any teardown `fun` saw implies a late return, and a starved
  # watchdog can't let a late `fun` through. It sends the caller nothing, and is
  # monitored only once `fun` is done, so a `receive` in `fun` can't swallow anything.
  defp guard_deadline(deadline, deadline_at, teardown, body) do
    ref = make_ref()
    caller = self()
    watchdog = spawn(fn -> watchdog(caller, ref, deadline, deadline_at, teardown) end)

    result =
      try do
        {:ok, body.({watchdog, ref, deadline_at})}
      catch
        kind, reason -> {kind, reason, __STACKTRACE__}
      end

    stop_watchdog(watchdog, ref)

    case result do
      {:ok, {^ref, :expired}} ->
        deadline_exceeded(%{deadline: deadline, outcome: :not_started})

      {:ok, {^ref, :finished, finished_at, outcome}} when finished_at >= deadline_at ->
        deadline_exceeded(%{deadline: deadline, outcome: outcome_tag(outcome)})

      {:ok, {^ref, :finished, _finished_at, outcome}} ->
        unwrap(outcome)

      # new_page/2 failed on its own: fire/4 waits for the page before tearing down.
      _ ->
        unwrap(result)
    end
  end

  # Can't hang: a fresh monitor on a dead watchdog is an immediate :DOWN, and a live
  # one exits on :cancel or once its (bounded) teardown returns.
  defp stop_watchdog(watchdog, ref) do
    mon = Process.monitor(watchdog)
    send(watchdog, {:cancel, ref})

    receive do
      {:DOWN, ^mon, :process, ^watchdog, _} -> :ok
    end
  end

  defp unwrap({:ok, value}), do: value
  defp unwrap({kind, reason, stacktrace}), do: :erlang.raise(kind, reason, stacktrace)

  # The returned error hides what `fun` did; telemetry keeps it.
  defp outcome_tag({:ok, {:error, _} = error}), do: error
  defp outcome_tag({:ok, _value}), do: :value

  defp outcome_tag({kind, reason, stacktrace}) do
    {:raised, kind, Exception.normalize(kind, reason, stacktrace)}
  end

  defp deadline_exceeded(metadata) do
    Telemetry.deadline_exceeded(metadata)
    {:error, :deadline_exceeded}
  end

  defp watchdog(caller, ref, deadline, deadline_at, teardown) do
    ProcessLabel.set({:cdp_deadline, deadline})
    caller_mon = Process.monitor(caller)
    watch(caller_mon, ref, deadline_at, teardown, nil)
  end

  defp watch(caller_mon, ref, deadline_at, teardown, page) do
    receive do
      {:cancel, ^ref} -> :ok
      {:page, ^ref, page} -> watch(caller_mon, ref, deadline_at, teardown, page)
      {:DOWN, ^caller_mon, :process, _, _} -> caller_down(teardown, page)
    after
      max(deadline_at - now_ms(), 0) ->
        # A just-in-time `fun` may have its cancel in flight; don't make it wait on a
        # teardown. (A cancel landing after this check still waits, bounded.)
        receive do
          {:cancel, ^ref} -> :ok
        after
          0 -> fire(caller_mon, ref, teardown, page)
        end
    end
  end

  # new_page can't be interrupted, and stopping the browser under it would exit the
  # caller's call; wait for the page (or for new_page to fail and the caller to cancel).
  defp fire(caller_mon, ref, teardown, nil) do
    receive do
      {:page, ^ref, page} -> fire(caller_mon, ref, teardown, page)
      {:cancel, ^ref} -> :ok
      {:DOWN, ^caller_mon, :process, _, _} -> :ok
    end
  end

  # Bounded, unlike stop/1, so a hung terminate can't hold stop_watchdog/2 forever. On
  # a timeout the terminate request stays queued and with_throwaway's own stop/1 follows.
  defp fire(_caller_mon, _ref, {:stop, browser}, _page) do
    safe(fn -> GenServer.stop(browser, :normal, 15_000) end)
  end

  defp fire(_caller_mon, _ref, {:close_page, browser}, page) do
    safe(fn -> close_page(browser, page) end)
  end

  # The link reaps a throwaway browser; nothing else closes a page on a caller-owned one.
  defp caller_down({:close_page, browser}, %Page{} = page) do
    safe(fn -> close_page(browser, page) end)
  end

  defp caller_down(_teardown, _page), do: :ok

  defp now_ms, do: System.monotonic_time(:millisecond)

  # Run a teardown action, swallowing an already-dead-process exit (or any raise)
  # so cleanup in `with_page/3` never overrides the operation's real outcome.
  defp safe(fun) do
    fun.()
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  # Remove the queued {:EXIT, browser, _} (delivered as a message because the
  # throwaway-browser `with_page/3` clause traps exits) so it can't leak to the
  # caller after the prior trap_exit flag is restored. A process exits once, but
  # take every match: this is the only drain a trapping caller gets.
  defp drain_exit(browser) do
    receive do
      {:EXIT, ^browser, _reason} -> drain_exit(browser)
    after
      0 -> :ok
    end
  end
end
