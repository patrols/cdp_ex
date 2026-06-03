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
  """

  alias CDPEx.Connection
  alias CDPEx.Protocol

  require Logger

  @navigate_timeout 30_000
  @evaluate_timeout 15_000
  @selector_timeout 5_000
  @screenshot_timeout 30_000
  @command_timeout 10_000

  @network_events ["Network.requestWillBeSent", "Network.responseReceived"]

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

  Options:
    * `:wait_until` — `:network_almost_idle` (default), `:load`, or `:none`
    * `:timeout` — ms (default 30_000)
  """
  @spec navigate(t(), String.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def navigate(%__MODULE__{} = page, url, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @navigate_timeout)
    wait_until = Keyword.get(opts, :wait_until, :network_almost_idle)
    navigate_with_wait(page, url, wait_until, timeout)
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
        drain_lifecycle(page.conn)
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
          drain_lifecycle(page.conn)
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

  # Flush lifecycle events left in our mailbox (other sessions/names, or stragglers
  # from a prior navigation) so they don't leak to the caller.
  defp drain_lifecycle(conn) do
    receive do
      {:cdp_event, ^conn, "Page.lifecycleEvent", _params, _sid} -> drain_lifecycle(conn)
    after
      0 -> :ok
    end
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

  defp decode_base64(base64, error) do
    case Base.decode64(base64) do
      {:ok, bytes} -> {:ok, bytes}
      :error -> {:error, error}
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

  # Page ops thread the page's session id (`nil` for a dedicated page) so the same
  # code path serves both the one-socket-per-page and the multiplexed transports.
  defp do_call(%__MODULE__{conn: conn, session_id: session_id}, method, params, timeout) do
    Connection.call(conn, method, params, timeout, session_id: session_id)
  end
end
