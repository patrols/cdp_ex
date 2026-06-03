defmodule CDPEx.Page do
  @moduledoc """
  A page (tab) handle and the operations you run against it.

  A `CDPEx.Page` is a lightweight struct — not a process — holding the page's
  `CDPEx.Connection` pid and target id. Operations are functions over that
  connection, so the OTP properties (supervision, crash isolation) live in the
  connection/browser layer while page calls stay ergonomic.

  Obtain one with `CDPEx.new_page/2`. If the underlying page dies (navigation to
  a new target, a crash), operations return `{:error, :noproc}` and you should
  open a fresh page.

  ## Operations

    * **Navigation** — `navigate/3`, `wait_for_navigation/2`
    * **Evaluation** — `evaluate/3`, `call_function/4`, `html/2`
    * **Waiting** — `wait_for_selector/3`, `wait_for_function/3`
    * **Elements** — `text/3`, `attribute/4`, `visible?/3`, `click/3`
    * **Capture** — `screenshot/2`, `pdf/2`
    * **Emulation** — `set_viewport/4`, `set_user_agent/3`
    * **Cookies & headers** — `cookies/2`, `set_cookies/3`, `clear_cookies/2`, `set_extra_headers/3`
    * **Network** — `observe_network/2`, `stop_observing_network/2`, `response_body/3`
    * **Interception** — `enable_request_interception/2`, `disable_request_interception/2`, `continue_request/3`, `fulfill_request/3`, `fail_request/3`
    * **Auth** — `authenticate/4` (proxy / HTTP Basic challenges)
  """

  alias CDPEx.Browser
  alias CDPEx.Connection
  alias CDPEx.Protocol

  require Logger

  @navigate_timeout 30_000
  @evaluate_timeout 15_000
  @selector_timeout 5_000
  @screenshot_timeout 30_000
  @command_timeout 10_000

  @lifecycle_method "Page.lifecycleEvent"
  @response_received "Network.responseReceived"
  @network_events ["Network.requestWillBeSent", @response_received]
  @fetch_paused "Fetch.requestPaused"

  @enforce_keys [:browser, :conn, :target_id]
  defstruct [:browser, :conn, :target_id, :session_id]

  @type t :: %__MODULE__{
          browser: pid(),
          conn: pid(),
          target_id: String.t(),
          session_id: String.t() | nil
        }

  @doc """
  Navigates to `url` and (by default) waits until the network is almost idle.

  Returns `{:ok, page}` so it pipelines with `with`. The readiness wait is
  best-effort: if it times out, navigation still returns `{:ok, page}` (the page
  may simply be slow); a hard navigation error returns `{:error, _}`.

  ## Capturing the document response

  Pass `response: true` to also get the main document's HTTP outcome — a clean signal
  for "did I land on the real page", versus a 403 wall / 404 / redirect-to-login that
  all otherwise look like success:

      {:ok, page, %{status: 200, url: final_url}} = Page.navigate(page, url, response: true)

  `status` is the HTTP status and `url` is the **final** URL after redirects,
  correlated to *this* navigation's main document by its `loaderId` (not "the first
  `Document` response seen"). This lazily enables the `Network` domain (and leaves it
  enabled). If no main document response arrives before the wait ends, it returns
  `{:error, {:no_document_response, url}}` (e.g. a same-document/hash navigation that
  loads no new document, or a connection that never produced an HTTP response — though
  the latter usually surfaces earlier as `{:navigate, _}`).

  > #### Don't combine with `observe_network/2` on the same page {: .warning}
  >
  > `response: true` subscribes the calling process to `Network.responseReceived` for
  > the duration of the call, then unsubscribes on the way out. If the *same process*
  > is also running `observe_network/2` on this page, the navigation tears that
  > subscription down. Observe from a separate process, or capture via `response: true`.

  Options:
    * `:wait_until` — `:network_almost_idle` (default), `:load`, or `:none`
    * `:response` — `true` to also return `%{status, url}` (default `false`)
    * `:timeout` — ms (default 30_000)
  """
  @spec navigate(t(), String.t(), keyword()) ::
          {:ok, t()}
          | {:ok, t(), %{status: non_neg_integer(), url: String.t()}}
          | {:error, term()}
  def navigate(%__MODULE__{} = page, url, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @navigate_timeout)
    wait_until = Keyword.get(opts, :wait_until, :network_almost_idle)

    if Keyword.get(opts, :response, false) do
      navigate_capturing_response(page, url, wait_until, timeout)
    else
      navigate_with_wait(page, url, wait_until, timeout)
    end
  end

  defp navigate_with_wait(page, url, :none, timeout) do
    case do_call(page, "Page.navigate", %{"url" => url}, timeout) do
      {:ok, %{"errorText" => error}} -> {:error, {:navigate, error}}
      {:ok, _result} -> {:ok, page}
      {:error, _} = error -> error
    end
  end

  defp navigate_with_wait(page, url, wait_until, timeout) do
    name = lifecycle_name(wait_until)

    # Issue the navigate (after subscribing — see subscribe_then_await/4) and wait
    # for its lifecycle milestone. The readiness wait is best-effort: a timeout
    # still returns {:ok, page} (the page may just be slow); a dead connection does not.
    trigger = fn ->
      case do_call(page, "Page.navigate", %{"url" => url}, timeout) do
        {:ok, %{"errorText" => error}} -> {:error, {:navigate, error}}
        {:ok, _result} -> :ok
        {:error, _} = error -> error
      end
    end

    case subscribe_then_await(page, name, timeout, trigger) do
      :reached ->
        {:ok, page}

      :timeout ->
        Logger.debug("[CDPEx.Page] readiness wait (#{name}) timed out; returning best-effort")
        {:ok, page}

      {:down, reason} ->
        {:error, down_reason(reason)}

      {:error, _} = error ->
        error
    end
  end

  # Like navigate_with_wait/4 but also captures the main-document Network.responseReceived
  # (HTTP status + final URL) for THIS navigation. Kept separate so the default path
  # stays untouched. Requires the Network domain; enables it lazily.
  defp navigate_capturing_response(page, url, wait_until, timeout) do
    # Validate :wait_until up front (lifecycle_name/1 raises on a bad value) so an
    # invalid option never enables Network / fires the navigation first — matching the
    # default path, which validates before any side effect.
    milestone = if wait_until == :none, do: nil, else: lifecycle_name(wait_until)
    methods = [@lifecycle_method, @response_received]

    with :ok <- ensure_network(page, timeout),
         :ok <- subscribe_each(page.conn, methods) do
      Enum.each(methods, &drain_events(page.conn, &1))
      ref = Process.monitor(page.conn)
      deadline = System.monotonic_time(:millisecond) + timeout

      try do
        capture_after_navigate(page, url, milestone, timeout, ref, deadline)
      after
        Process.demonitor(ref, [:flush])
        unsubscribe_each(page.conn, methods)
        Enum.each(methods, &drain_events(page.conn, &1))
      end
    end
  end

  defp capture_after_navigate(page, url, milestone, timeout, ref, deadline) do
    case do_call(page, "Page.navigate", %{"url" => url}, timeout) do
      {:ok, %{"errorText" => error}} ->
        {:error, {:navigate, error}}

      {:ok, result} ->
        case await_capture(
               page,
               milestone,
               ref,
               deadline,
               result["loaderId"],
               result["frameId"],
               nil
             ) do
          {:ok, nil} -> {:error, {:no_document_response, url}}
          {:ok, resp} -> {:ok, page, resp}
          {:down, reason} -> {:error, down_reason(reason)}
        end

      {:error, _} = error ->
        error
    end
  end

  # Await the readiness milestone (or, with :none, the document response itself) while
  # accumulating the main-document response — scoped to this page's session (`^sid`),
  # correlated by loaderId (+ frameId when present) and type "Document".
  defp await_capture(
         %__MODULE__{conn: conn, session_id: sid} = page,
         milestone,
         ref,
         deadline,
         lid,
         fid,
         captured
       ) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:cdp_event, ^conn, @response_received, params, ^sid} ->
        captured =
          if document_response?(params, lid, fid), do: response_summary(params), else: captured

        if is_nil(milestone) and not is_nil(captured) do
          {:ok, captured}
        else
          await_capture(page, milestone, ref, deadline, lid, fid, captured)
        end

      {:cdp_event, ^conn, @lifecycle_method, %{"name" => ^milestone}, ^sid}
      when not is_nil(milestone) ->
        {:ok, captured}

      {:cdp_event, ^conn, _method, _params, _other_sid} ->
        # Another session's event, or this session's non-milestone lifecycle — ignore.
        await_capture(page, milestone, ref, deadline, lid, fid, captured)

      {:DOWN, ^ref, :process, ^conn, reason} ->
        {:down, reason}
    after
      remaining ->
        # Best-effort: return whatever document response we captured (nil → the caller
        # maps it to {:error, {:no_document_response, _}}). Prefer a just-landed :DOWN.
        receive do
          {:DOWN, ^ref, :process, ^conn, reason} -> {:down, reason}
        after
          0 -> {:ok, captured}
        end
    end
  end

  # The main document response for THIS navigation: type "Document", matching loaderId
  # (+ frameId when the navigate result carried one), and a well-formed response (an
  # integer status and a URL). Requiring both keeps the {:ok, page, %{status, url}}
  # contract honest — a degenerate response missing them is not reported as the landing,
  # so the call falls through to {:error, {:no_document_response, _}} rather than
  # returning nils. (Real Chrome always populates both on a Document response.)
  defp document_response?(
         %{
           "type" => "Document",
           "loaderId" => loader,
           "response" => %{"status" => status, "url" => url}
         } = params,
         lid,
         fid
       )
       when is_integer(status) and is_binary(url) do
    loader == lid and Map.get(params, "frameId", fid) == fid
  end

  defp document_response?(_params, _lid, _fid), do: false

  defp response_summary(%{"response" => response}) do
    %{status: response["status"], url: response["url"]}
  end

  # Generic mailbox drain for one cdp method.
  defp drain_events(conn, method) do
    receive do
      {:cdp_event, ^conn, ^method, _params, _sid} -> drain_events(conn, method)
    after
      0 -> :ok
    end
  end

  # Subscribe to lifecycle events, run `trigger` (issue the navigation, or a no-op),
  # then await the `name` milestone — always unsubscribing + draining on the way out.
  # Subscribing BEFORE `trigger` closes the race where a fast event (e.g. `load` on
  # a cached page) fires before the listener is in place. Returns await_lifecycle/4's
  # outcome (`:reached` | `{:down, reason}` | `:timeout`), or `{:error, reason}` when
  # subscription fails or `trigger` returns one.
  defp subscribe_then_await(page, name, timeout, trigger) do
    case safe_subscribe(page.conn) do
      {:error, reason} ->
        {:error, reason}

      :ok ->
        drain_events(page.conn, @lifecycle_method)
        ref = Process.monitor(page.conn)
        deadline = System.monotonic_time(:millisecond) + timeout

        try do
          case trigger.() do
            :ok -> await_lifecycle(page, name, ref, deadline)
            {:error, _} = error -> error
          end
        after
          Process.demonitor(ref, [:flush])
          safe_unsubscribe(page.conn)
          drain_events(page.conn, @lifecycle_method)
        end
    end
  end

  # Wait for the named lifecycle event — scoped to this page's session (`^sid`) and
  # the `Page.lifecycleEvent` method (the subscription is method-keyed, so other
  # methods never arrive here) — the connection dying, or the deadline. Returns
  # `:reached` | `{:down, reason}` | `:timeout`; callers map it to their own contract.
  defp await_lifecycle(%__MODULE__{conn: conn, session_id: sid} = page, name, ref, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:cdp_event, ^conn, "Page.lifecycleEvent", %{"name" => ^name}, ^sid} ->
        :reached

      {:cdp_event, ^conn, "Page.lifecycleEvent", _params, _session_id} ->
        await_lifecycle(page, name, ref, deadline)

      {:DOWN, ^ref, :process, ^conn, reason} ->
        {:down, reason}
    after
      remaining ->
        # Exact deadline-vs-DOWN tie: a {:DOWN} may have just landed but lost the
        # race to `after`. Prefer it over a misleading timeout.
        receive do
          {:DOWN, ^ref, :process, ^conn, reason} -> {:down, reason}
        after
          0 -> :timeout
        end
    end
  end

  defp down_reason({:shutdown, {:ws_closed, reason}}), do: {:ws_closed, reason}
  defp down_reason(_), do: :noproc

  # subscribe/unsubscribe are GenServer.calls; a connection that's already dead (or
  # dies mid-navigation) would otherwise make them exit and crash navigate/3 —
  # which must instead return {:error, _}. Treat (un)subscription as best-effort.
  defp safe_subscribe(conn) do
    Connection.subscribe(conn, "Page.lifecycleEvent")
  catch
    :exit, _ -> {:error, :noproc}
  end

  defp safe_unsubscribe(conn) do
    Connection.unsubscribe(conn, "Page.lifecycleEvent")
  catch
    :exit, _ -> :ok
  end

  defp lifecycle_name(:load), do: "load"
  defp lifecycle_name(:network_almost_idle), do: "networkAlmostIdle"

  # Both navigate/3 and wait_for_navigation/2 route through here. Fail fast on an
  # unknown value rather than silently waiting for the wrong milestone (`:none` is
  # handled by the callers before this point).
  defp lifecycle_name(other) do
    raise ArgumentError,
          "invalid :wait_until #{inspect(other)} (expected :network_almost_idle, :load, or :none)"
  end

  @doc """
  Waits for a navigation lifecycle milestone, without issuing a navigation.

  Useful after a `click/3` (or other in-page action) that triggers navigation.

  Options:
    * `:wait_until` — `:network_almost_idle` (default), `:load`, or `:none`
    * `:timeout` — ms (default 30_000)

  Returns `:ok`, `{:error, :timeout}`, or `{:error, reason}` if the connection
  drops while waiting.
  """
  @spec wait_for_navigation(t(), keyword()) :: :ok | {:error, term()}
  def wait_for_navigation(%__MODULE__{} = page, opts \\ []) do
    case Keyword.get(opts, :wait_until, :network_almost_idle) do
      :none -> :ok
      wait_until -> await_navigation(page, wait_until, opts)
    end
  end

  # Same machinery as navigate/3 (subscribe-before-wait, scoped to this session +
  # the Page.lifecycleEvent method) but without issuing a navigation — the caller
  # already triggered one (e.g. a click). Unlike the previous await_event matcher,
  # this can't be tripped by params from another event method carrying a "name".
  defp await_navigation(page, wait_until, opts) do
    name = lifecycle_name(wait_until)
    timeout = Keyword.get(opts, :timeout, @navigate_timeout)

    case subscribe_then_await(page, name, timeout, fn -> :ok end) do
      :reached -> :ok
      :timeout -> {:error, :timeout}
      {:down, reason} -> {:error, down_reason(reason)}
      {:error, _} = error -> error
    end
  end

  @doc """
  Arms HTTP/proxy authentication on this page with `username`/`password`.

  Headless Chrome launched with `--proxy-server=host:port` can't send proxy
  credentials, so an authenticated proxy rejects the connection
  (`net::ERR_INVALID_AUTH_CREDENTIALS`). Call this after `new_page/2` and
  **before** `navigate/3`: it answers the proxy (or HTTP Basic) auth challenge with
  the given credentials. It also covers Basic-auth-gated origins.

  This enables the CDP `Fetch` domain for the page, which pauses (and
  auto-continues) **every** request — measurable overhead on heavy pages.

  Only `:dedicated` pages (the `new_page/2` default) are supported; a `:session`
  page returns `{:error, {:unsupported_transport, :session}}`. A page that isn't one
  of this browser's open pages returns `{:error, :unknown_page}`, a page that is
  already authenticated returns `{:error, :already_authenticated}`, and a page that
  already has request interception enabled returns `{:error, {:conflict, :intercepting}}`
  (auth and interception both drive the `Fetch` domain — use one per page).

  The bad-credentials loop guard keys on the request id, so a single request that
  must answer **both** a proxy and an origin challenge isn't supported — the second
  challenge is cancelled (Puppeteer-parity).

  Options:
    * `:source` — which challenges to answer: `:any` (default), `:proxy`, `:server`.
      An unknown value returns `{:error, {:invalid_source, value}}`.
  """
  @spec authenticate(t(), String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def authenticate(%__MODULE__{} = page, username, password, opts \\ [])
      when is_binary(username) and is_binary(password) do
    case validate_source(Keyword.get(opts, :source, :any)) do
      :ok ->
        Browser.authenticate(page.browser, page, [username: username, password: password] ++ opts)

      {:error, _} = error ->
        error
    end
  end

  defp validate_source(source) when source in [:any, :proxy, :server], do: :ok
  defp validate_source(source), do: {:error, {:invalid_source, source}}

  @doc """
  Evaluates a JavaScript expression and returns its value (`returnByValue`).

  A thrown JS exception is `{:error, {:evaluate_exception, details}}`.

  Options: `:timeout` (default 15_000), `:await_promise` (default `false`).
  """
  @spec evaluate(t(), String.t(), keyword()) :: {:ok, term()} | {:error, term()}
  def evaluate(%__MODULE__{} = page, js, opts \\ []) when is_binary(js) do
    timeout = Keyword.get(opts, :timeout, @evaluate_timeout)

    params = %{
      "expression" => js,
      "returnByValue" => true,
      "awaitPromise" => Keyword.get(opts, :await_promise, false)
    }

    case do_call(page, "Runtime.evaluate", params, timeout) do
      {:ok, result} -> Protocol.evaluate_result(result)
      {:error, _} = error -> error
    end
  end

  @doc "Returns the page's full serialized HTML (`document.documentElement.outerHTML`)."
  @spec html(t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def html(%__MODULE__{} = page, opts \\ []) do
    evaluate(page, "document.documentElement.outerHTML", opts)
  end

  @doc """
  Calls a JavaScript function with `args` and returns its value.

  `function_declaration` is a JS function expression (e.g. `"(a, b) => a + b"`).
  `args` are JSON-encoded (not string-interpolated) before being applied, so
  passing data values through them is safe. A thrown exception is
  `{:error, {:evaluate_exception, details}}`; non-serializable `args` return
  `{:error, {:invalid_args, reason}}`.

  > #### Trusted input {: .warning}
  >
  > `function_declaration` is interpolated into the page script **verbatim** —
  > treat it as trusted code and never build it from untrusted input.

  Options: `:timeout` (default 15_000), `:await_promise` (default `false`).
  """
  @spec call_function(t(), String.t(), [term()], keyword()) :: {:ok, term()} | {:error, term()}
  def call_function(%__MODULE__{} = page, function_declaration, args \\ [], opts \\ [])
      when is_binary(function_declaration) and is_list(args) do
    case Jason.encode(args) do
      {:ok, json} ->
        evaluate(page, "(#{function_declaration}).apply(undefined, #{json})", opts)

      {:error, reason} ->
        {:error, {:invalid_args, reason}}
    end
  end

  @doc """
  Polls until `css` matches an element, or `timeout` elapses.

  Returns `:ok`, `{:error, :timeout}`, or `{:error, reason}` if a non-transient
  evaluate error occurs (e.g. the connection drops). Options: `:timeout`
  (default 5_000), `:interval` (poll interval ms, default 100).
  """
  @spec wait_for_selector(t(), String.t(), keyword()) :: :ok | {:error, term()}
  def wait_for_selector(%__MODULE__{} = page, css, opts \\ []) when is_binary(css) do
    wait_for_function(page, "document.querySelector(#{Jason.encode!(css)}) !== null", opts)
  end

  @doc """
  Polls a JavaScript expression until it is truthy, or `timeout` elapses.

  The expression is coerced with `!!(...)`, so JS truthiness applies. Returns
  `:ok`, `{:error, :timeout}`, or `{:error, reason}` if a non-transient evaluate
  error occurs (e.g. a thrown exception or a dropped connection). Options:
  `:timeout` (default 5_000), `:interval` (poll interval ms, default 100).
  """
  @spec wait_for_function(t(), String.t(), keyword()) :: :ok | {:error, term()}
  def wait_for_function(%__MODULE__{} = page, js, opts \\ []) when is_binary(js) do
    timeout = Keyword.get(opts, :timeout, @selector_timeout)
    interval = Keyword.get(opts, :interval, 100)
    deadline = System.monotonic_time(:millisecond) + timeout
    poll_truthy(page, "!!(#{js})", interval, deadline)
  end

  defp poll_truthy(page, js, interval, deadline) do
    case probe_truthy(page, js) do
      :truthy ->
        :ok

      {:fatal, reason} ->
        {:error, reason}

      :falsy ->
        if System.monotonic_time(:millisecond) >= deadline do
          {:error, :timeout}
        else
          Process.sleep(interval)
          poll_truthy(page, js, interval, deadline)
        end
    end
  end

  defp probe_truthy(page, js) do
    case evaluate(page, js) do
      {:ok, true} ->
        :truthy

      {:ok, _falsy} ->
        :falsy

      # A CDP error here is typically transient (e.g. the execution context is
      # not ready mid-navigation). Keep polling until the deadline rather than
      # failing hard — that's the point of a wait.
      {:error, {:cdp_error, _method, _info}} ->
        :falsy

      {:error, reason} ->
        {:fatal, reason}
    end
  end

  @doc """
  Returns the `textContent` of the first element matching `css`, or `nil` when
  no element matches.
  """
  @spec text(t(), String.t(), keyword()) :: {:ok, String.t() | nil} | {:error, term()}
  def text(%__MODULE__{} = page, css, opts \\ []) when is_binary(css) do
    sel = Jason.encode!(css)

    js = """
    (() => {
      const el = document.querySelector(#{sel});
      return el ? el.textContent : null;
    })()
    """

    evaluate(page, js, opts)
  end

  @doc """
  Returns attribute `name` of the first element matching `css`, or `nil` when the
  element or attribute is absent.
  """
  @spec attribute(t(), String.t(), String.t(), keyword()) ::
          {:ok, String.t() | nil} | {:error, term()}
  def attribute(%__MODULE__{} = page, css, name, opts \\ [])
      when is_binary(css) and is_binary(name) do
    sel = Jason.encode!(css)
    attr = Jason.encode!(name)

    js = """
    (() => {
      const el = document.querySelector(#{sel});
      return el ? el.getAttribute(#{attr}) : null;
    })()
    """

    evaluate(page, js, opts)
  end

  @doc """
  Returns `{:ok, true}` when the first element matching `css` is rendered and
  visible (has layout boxes, not `display: none` / `visibility: hidden`),
  `{:ok, false}` otherwise — including when no element matches.
  """
  @spec visible?(t(), String.t(), keyword()) :: {:ok, boolean()} | {:error, term()}
  def visible?(%__MODULE__{} = page, css, opts \\ []) when is_binary(css) do
    sel = Jason.encode!(css)

    js = """
    (() => {
      const el = document.querySelector(#{sel});
      if (!el) return false;
      const s = window.getComputedStyle(el);
      return el.getClientRects().length > 0 && s.visibility !== "hidden" && s.display !== "none";
    })()
    """

    evaluate(page, js, opts)
  end

  @doc """
  Clicks the first element matching `css` (a synthetic JS `.click()`).

  Returns `:ok`, or `{:error, {:selector_not_found, css}}` when nothing matches.
  """
  @spec click(t(), String.t(), keyword()) :: :ok | {:error, term()}
  def click(%__MODULE__{} = page, css, opts \\ []) when is_binary(css) do
    selector = Jason.encode!(css)

    js = """
    (function () {
      var el = document.querySelector(#{selector});
      if (!el) { return false; }
      el.click();
      return true;
    })()
    """

    case evaluate(page, js, opts) do
      {:ok, true} -> :ok
      {:ok, false} -> {:error, {:selector_not_found, css}}
      {:error, _} = error -> error
    end
  end

  @doc """
  Captures a PNG screenshot.

  Returns `{:ok, data}` where `data` is the PNG bytes — or, when `:path` is
  given, the written file path (also a binary).

  Options: `:path` (write to file), `:full_page` (capture beyond the viewport,
  default `false`), `:timeout` (default 30_000).
  """
  @spec screenshot(t(), keyword()) :: {:ok, binary()} | {:error, term()}
  def screenshot(%__MODULE__{} = page, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @screenshot_timeout)

    params = maybe_full_page(%{"format" => "png"}, Keyword.get(opts, :full_page, false))

    with {:ok, %{"data" => base64}} <-
           do_call(page, "Page.captureScreenshot", params, timeout),
         {:ok, bytes} <- decode_base64(base64, :invalid_screenshot_data) do
      write_or_return(bytes, Keyword.get(opts, :path))
    end
  end

  @doc """
  Returns all browser cookies as a list of CDP cookie maps.

  Lazily enables the `Network` domain. Options: `:timeout` (default 10_000).
  """
  @spec cookies(t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def cookies(%__MODULE__{} = page, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @command_timeout)

    with :ok <- ensure_network(page, timeout),
         {:ok, %{"cookies" => cookies}} <-
           do_call(page, "Network.getAllCookies", %{}, timeout) do
      {:ok, cookies}
    end
  end

  @doc """
  Sets cookies. Each is a CDP `CookieParam` map — at least `"name"`, `"value"`,
  and a `"url"` or `"domain"`. Lazily enables `Network`. Options: `:timeout`.
  """
  @spec set_cookies(t(), [map()], keyword()) :: :ok | {:error, term()}
  def set_cookies(%__MODULE__{} = page, cookies, opts \\ []) when is_list(cookies) do
    timeout = Keyword.get(opts, :timeout, @command_timeout)

    with :ok <- ensure_network(page, timeout),
         {:ok, _} <-
           do_call(page, "Network.setCookies", %{"cookies" => cookies}, timeout) do
      :ok
    end
  end

  @doc "Clears all browser cookies. Lazily enables `Network`. Options: `:timeout`."
  @spec clear_cookies(t(), keyword()) :: :ok | {:error, term()}
  def clear_cookies(%__MODULE__{} = page, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @command_timeout)

    with :ok <- ensure_network(page, timeout),
         {:ok, _} <- do_call(page, "Network.clearBrowserCookies", %{}, timeout) do
      :ok
    end
  end

  @doc """
  Starts observing network traffic, delivering CDP `Network` events to the calling
  process.

  Subscribes the caller to `:events` (default the request + response lifecycle),
  then enables the `Network` domain (idempotent). Each event arrives as
  `{:cdp_event, conn, method, params, session_id}` — handle them in a `handle_info`.
  Call `stop_observing_network/2` to unsubscribe.

  Start observing **before** navigating: requests already in flight when you call
  this are not captured. On a session-transport page the caller receives **every**
  session's events on the shared connection (subscriptions are keyed by method, not
  session); match on the `session_id` element to filter to this page.

  Options:
    * `:events` — `Network.*` method names (default request + response lifecycle)
    * `:timeout` — ms for the enable call (default 10_000)
  """
  @spec observe_network(t(), keyword()) :: :ok | {:error, term()}
  def observe_network(%__MODULE__{} = page, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @command_timeout)
    methods = Keyword.get(opts, :events, @network_events)

    # Subscribe BEFORE enabling so an event emitted the instant the domain turns on
    # can't slip through before the caller is registered (mirrors navigate/3's
    # subscribe-before-trigger).
    with :ok <- subscribe_each(page.conn, methods),
         :ok <- ensure_network(page, timeout) do
      :ok
    else
      {:error, _} = error ->
        # Enable failed — undo the subscriptions we just added. This drops every
        # method in `methods`; if the caller had independently subscribed to one of
        # them beforehand, that subscription goes too (an accepted edge case —
        # observe_network owns the lifecycle of the methods it is given).
        unsubscribe_each(page.conn, methods)
        error
    end
  end

  @doc """
  Stops observing — unsubscribes the caller from the network `:events`. Leaves the
  `Network` domain enabled.

  Pass the **same** `:events` you gave `observe_network/2`. Both default to the
  request + response lifecycle, but if you observed with a custom list you must
  repeat it here — otherwise the original subscriptions are never removed and the
  caller keeps receiving those events.
  """
  @spec stop_observing_network(t(), keyword()) :: :ok
  def stop_observing_network(%__MODULE__{} = page, opts \\ []) do
    unsubscribe_each(page.conn, Keyword.get(opts, :events, @network_events))
  end

  @doc """
  Returns a response's body by its `request_id` (from a `Network.responseReceived`
  event), via `Network.getResponseBody`.

  Returns `{:ok, body}` (decoding base64 when Chrome sends it that way) or
  `{:error, reason}`. The `Network` domain must have been enabled (e.g. via
  `observe_network/2`) **when the request was captured** — unlike the other Network
  ops this does not lazily enable it, since enabling now can't recover a past body.
  If it wasn't enabled, the call surfaces as
  `{:error, {:cdp_error, "Network.getResponseBody", _}}`. Options: `:timeout`
  (default 10_000).
  """
  @spec response_body(t(), String.t(), keyword()) :: {:ok, binary()} | {:error, term()}
  def response_body(%__MODULE__{} = page, request_id, opts \\ []) when is_binary(request_id) do
    timeout = Keyword.get(opts, :timeout, @command_timeout)

    case do_call(page, "Network.getResponseBody", %{"requestId" => request_id}, timeout) do
      {:ok, %{"body" => body, "base64Encoded" => true}} ->
        decode_base64(body, :invalid_response_body)

      {:ok, %{"body" => body}} ->
        {:ok, body}

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Enables request interception: pauses matching requests and delivers a
  `Fetch.requestPaused` event to the calling process for each one. You must then
  resolve **every** paused request with `continue_request/3`, `fulfill_request/3`,
  or `fail_request/3` (keyed by its `"requestId"`) — an unresolved request stalls
  the page.

  Each pause arrives as `{:cdp_event, conn, "Fetch.requestPaused", params, session_id}`;
  handle it in a `handle_info`. The caller is subscribed **before** the domain is
  enabled, so no paused request is missed.

  > #### Drive interception from one long-lived process {: .info}
  >
  > Use the **same process** for `enable_request_interception/2`, the pause handling,
  > and `disable_request_interception/2` — the subscription is keyed to its pid. That
  > process is registered with the browser as the interception owner: if it exits
  > without disabling, the browser auto-`Fetch.disable`s the page, so a crashed or
  > forgetful caller can't leave it bricked (every request paused with no resolver).
  > While interception is enabled you must still resolve every pause.

  Only `:dedicated` pages are supported; a `:session`-transport page is rejected with
  `{:error, {:unsupported_transport, :session}}` (mirroring `authenticate/4`) — its
  subscription and owner-monitor would outlive `close_page`, which never stops the
  shared browser connection.

  Mutually exclusive with `authenticate/4` on the same page — both drive the `Fetch`
  domain. The conflict is **enforced**: enabling interception on an authenticated page
  returns `{:error, {:conflict, :authenticated}}`, and `authenticate/4` on an
  intercepting page returns `{:error, {:conflict, :intercepting}}`. Re-enabling
  interception on a page that already has it returns `{:error, :already_intercepting}`.

  Options:
    * `:patterns` — CDP `RequestPattern`s (default `[%{"urlPattern" => "*"}]`, all requests)
    * `:timeout` — ms for the enable call (default 10_000)
  """
  @spec enable_request_interception(t(), keyword()) :: :ok | {:error, term()}
  def enable_request_interception(%__MODULE__{} = page, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @command_timeout)
    patterns = Keyword.get(opts, :patterns, [%{"urlPattern" => "*"}])

    # Reserve the page's Fetch domain with the browser first: it enforces mutual
    # exclusion with authenticate/4 and monitors this process so the domain is
    # auto-disabled if we die. Only on a successful reservation do we subscribe +
    # enable (on this process, mirroring observe_network/2); roll both back on failure.
    case Browser.reserve_interception(page.browser, page) do
      :ok ->
        with :ok <- subscribe_each(page.conn, [@fetch_paused]),
             {:ok, _} <- do_call(page, "Fetch.enable", %{"patterns" => patterns}, timeout) do
          :ok
        else
          {:error, _} = error ->
            unsubscribe_each(page.conn, [@fetch_paused])
            # A client-side timeout can mean Chrome actually enabled Fetch; disable it
            # best-effort before releasing, so a timed-out enable can't leave the page
            # bricked (Fetch on, no resolver) with the reservation/monitor already gone.
            _ = ok_call(page, "Fetch.disable", %{}, timeout)
            Browser.release_interception(page.browser, page)
            error
        end

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Disables request interception — unsubscribes the caller from `Fetch.requestPaused`
  and disables the `Fetch` domain. Resolve any still-paused requests first.

  Call this from the **same process** that called `enable_request_interception/2`:
  the unsubscribe is keyed to `self()`, so a disable from a different process leaves
  the original subscriber still receiving (now-unresolvable) pauses.
  """
  @spec disable_request_interception(t(), keyword()) :: :ok | {:error, term()}
  def disable_request_interception(%__MODULE__{} = page, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @command_timeout)
    unsubscribe_each(page.conn, [@fetch_paused])
    result = ok_call(page, "Fetch.disable", %{}, timeout)
    # Release the browser-side reservation (demonitors this process) regardless of the
    # disable result, so the eventual owner :DOWN can't re-issue a spurious disable.
    Browser.release_interception(page.browser, page)
    result
  end

  @doc """
  Lets a paused request proceed (`Fetch.continueRequest`), optionally rewriting it.

  `:url`, `:method`, and `:headers` are **verbatim overrides, not merges**. In
  particular `:headers` *replaces the entire request header set*, so passing it to
  set one header drops everything Chrome would otherwise send (`User-Agent`,
  `Accept`, `Cookie`, …). Omit `:headers` to leave the original request headers
  intact (the same gotcha as Puppeteer's `continueRequest({headers})`).

  Options (all optional): `:url`, `:method`, `:headers` (a name => value map or
  keyword list), `:post_data` (a binary or iodata, base64-encoded for you), `:timeout`.
  """
  @spec continue_request(t(), String.t(), keyword()) :: :ok | {:error, term()}
  def continue_request(%__MODULE__{} = page, request_id, opts \\ []) when is_binary(request_id) do
    timeout = Keyword.get(opts, :timeout, @command_timeout)

    params =
      %{"requestId" => request_id}
      |> put_present("url", Keyword.get(opts, :url))
      |> put_present("method", Keyword.get(opts, :method))
      |> put_present("headers", header_entries(Keyword.get(opts, :headers)))
      |> put_present("postData", encode64(Keyword.get(opts, :post_data)))

    ok_call(page, "Fetch.continueRequest", params, timeout)
  end

  @doc """
  Answers a paused request with a synthetic response (`Fetch.fulfillRequest`) — the
  page never hits the network for it.

  Options: `:status` (response code, default 200), `:headers` (a name => value map or
  keyword list), `:body` (a binary or iodata, base64-encoded for you), `:timeout`.
  """
  @spec fulfill_request(t(), String.t(), keyword()) :: :ok | {:error, term()}
  def fulfill_request(%__MODULE__{} = page, request_id, opts \\ []) when is_binary(request_id) do
    timeout = Keyword.get(opts, :timeout, @command_timeout)

    params =
      %{"requestId" => request_id, "responseCode" => Keyword.get(opts, :status, 200)}
      |> put_present("responseHeaders", header_entries(Keyword.get(opts, :headers)))
      |> put_present("body", encode64(Keyword.get(opts, :body)))

    ok_call(page, "Fetch.fulfillRequest", params, timeout)
  end

  @doc """
  Fails a paused request (`Fetch.failRequest`).

  `:reason` (default `:failed`) is one of `:failed`, `:aborted`, `:timed_out`,
  `:access_denied`, `:connection_closed`, `:connection_reset`, `:connection_refused`,
  `:name_not_resolved`, `:internet_disconnected`, `:address_unreachable`,
  `:blocked_by_client`, `:blocked_by_response`. An unknown value returns
  `{:error, {:invalid_error_reason, value}}`.
  """
  @spec fail_request(t(), String.t(), keyword()) :: :ok | {:error, term()}
  def fail_request(%__MODULE__{} = page, request_id, opts \\ []) when is_binary(request_id) do
    timeout = Keyword.get(opts, :timeout, @command_timeout)

    case error_reason(Keyword.get(opts, :reason, :failed)) do
      {:ok, reason} ->
        ok_call(
          page,
          "Fetch.failRequest",
          %{"requestId" => request_id, "errorReason" => reason},
          timeout
        )

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Sets extra HTTP headers sent with every subsequent request on this page.

  `headers` is a map of header name => value; set them before navigating for
  them to apply to that navigation. Lazily enables `Network`. Options: `:timeout`.
  """
  @spec set_extra_headers(t(), %{optional(String.t()) => String.t()}, keyword()) ::
          :ok | {:error, term()}
  def set_extra_headers(%__MODULE__{} = page, headers, opts \\ []) when is_map(headers) do
    timeout = Keyword.get(opts, :timeout, @command_timeout)

    with :ok <- ensure_network(page, timeout),
         {:ok, _} <-
           do_call(
             page,
             "Network.setExtraHTTPHeaders",
             %{"headers" => headers},
             timeout
           ) do
      :ok
    end
  end

  @doc """
  Overrides the page's User-Agent (`Emulation.setUserAgentOverride`).

  Options: `:timeout` (default 10_000).
  """
  @spec set_user_agent(t(), String.t(), keyword()) :: :ok | {:error, term()}
  def set_user_agent(%__MODULE__{} = page, user_agent, opts \\ []) when is_binary(user_agent) do
    timeout = Keyword.get(opts, :timeout, @command_timeout)
    params = %{"userAgent" => user_agent}

    case do_call(page, "Emulation.setUserAgentOverride", params, timeout) do
      {:ok, _} -> :ok
      {:error, _} = error -> error
    end
  end

  @doc """
  Overrides the viewport via `Emulation.setDeviceMetricsOverride`.

  `width`/`height` are CSS pixels. Options: `:device_scale_factor` (default 1),
  `:mobile` (default `false`), `:timeout`. Returns `:ok`.
  """
  @spec set_viewport(t(), pos_integer(), pos_integer(), keyword()) :: :ok | {:error, term()}
  def set_viewport(%__MODULE__{} = page, width, height, opts \\ [])
      when is_integer(width) and width > 0 and is_integer(height) and height > 0 do
    timeout = Keyword.get(opts, :timeout, @command_timeout)

    params = %{
      "width" => width,
      "height" => height,
      "deviceScaleFactor" => Keyword.get(opts, :device_scale_factor, 1),
      "mobile" => Keyword.get(opts, :mobile, false)
    }

    case do_call(page, "Emulation.setDeviceMetricsOverride", params, timeout) do
      {:ok, _} -> :ok
      {:error, _} = error -> error
    end
  end

  @doc """
  Renders the page to PDF (`Page.printToPDF`).

  Returns `{:ok, data}` where `data` is the PDF bytes — or, when `:path` is
  given, the written file path (also a binary). Options: `:path`, `:landscape`
  (default `false`), `:print_background` (default `true`), `:timeout` (default 30_000).
  """
  @spec pdf(t(), keyword()) :: {:ok, binary()} | {:error, term()}
  def pdf(%__MODULE__{} = page, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @screenshot_timeout)

    params = %{
      "landscape" => Keyword.get(opts, :landscape, false),
      "printBackground" => Keyword.get(opts, :print_background, true)
    }

    with {:ok, %{"data" => base64}} <-
           do_call(page, "Page.printToPDF", params, timeout),
         {:ok, bytes} <- decode_base64(base64, :invalid_pdf_data) do
      write_or_return(bytes, Keyword.get(opts, :path))
    end
  end

  defp maybe_full_page(params, true), do: Map.put(params, "captureBeyondViewport", true)
  defp maybe_full_page(params, false), do: params

  defp decode_base64(base64, error_tag) do
    case Base.decode64(base64) do
      {:ok, bytes} -> {:ok, bytes}
      :error -> {:error, {error_tag, String.slice(base64, 0, 500)}}
    end
  end

  defp write_or_return(bytes, nil), do: {:ok, bytes}

  defp write_or_return(bytes, path) do
    case File.write(path, bytes) do
      :ok -> {:ok, path}
      {:error, reason} -> {:error, {:write_failed, reason}}
    end
  end

  # Lazily enable the Network domain (idempotent in CDP) so cookie/header ops
  # work without callers opting in at page creation — keeps Page stateless.
  defp ensure_network(page, timeout) do
    case do_call(page, "Network.enable", %{}, timeout) do
      {:ok, _} -> :ok
      {:error, _} = error -> error
    end
  end

  # Subscribe/unsubscribe the caller to a list of event methods, tolerating a
  # connection that died mid-call so the observe ops surface {:error, :noproc} / :ok
  # rather than crashing the caller.
  defp subscribe_each(conn, methods) do
    Enum.each(methods, &Connection.subscribe(conn, &1))
    :ok
  catch
    :exit, _ -> {:error, :noproc}
  end

  defp unsubscribe_each(conn, methods) do
    Enum.each(methods, &Connection.unsubscribe(conn, &1))
    :ok
  catch
    :exit, _ -> :ok
  end

  defp ok_call(page, method, params, timeout) do
    case do_call(page, method, params, timeout) do
      {:ok, _} -> :ok
      {:error, _} = error -> error
    end
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp header_entries(nil), do: nil

  # Accept a map or a keyword list (both are natural for headers); Enum.map handles
  # either's {name, value} pairs. A genuinely-wrong shape still raises.
  defp header_entries(headers) when is_map(headers) or is_list(headers) do
    Enum.map(headers, fn {name, value} ->
      %{"name" => to_string(name), "value" => to_string(value)}
    end)
  end

  defp encode64(nil), do: nil
  # Accept a binary or iodata — IO.iodata_to_binary/1 flattens either (and a
  # genuinely-wrong type, e.g. an integer, still raises).
  defp encode64(data), do: Base.encode64(IO.iodata_to_binary(data))

  @error_reasons %{
    failed: "Failed",
    aborted: "Aborted",
    timed_out: "TimedOut",
    access_denied: "AccessDenied",
    connection_closed: "ConnectionClosed",
    connection_reset: "ConnectionReset",
    connection_refused: "ConnectionRefused",
    name_not_resolved: "NameNotResolved",
    internet_disconnected: "InternetDisconnected",
    address_unreachable: "AddressUnreachable",
    blocked_by_client: "BlockedByClient",
    blocked_by_response: "BlockedByResponse"
  }

  defp error_reason(reason) do
    case Map.fetch(@error_reasons, reason) do
      {:ok, cdp} -> {:ok, cdp}
      :error -> {:error, {:invalid_error_reason, reason}}
    end
  end

  # Page ops thread the page's session id (`nil` for a dedicated page) so the same
  # code path serves both the one-socket-per-page and the multiplexed transports.
  defp do_call(%__MODULE__{conn: conn, session_id: session_id}, method, params, timeout) do
    Connection.call(conn, method, params, timeout, session_id: session_id)
  end
end
