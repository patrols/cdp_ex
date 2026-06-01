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
  """

  alias CDPEx.Connection
  alias CDPEx.Protocol

  require Logger

  @navigate_timeout 30_000
  @evaluate_timeout 15_000
  @selector_timeout 5_000
  @screenshot_timeout 30_000

  @enforce_keys [:browser, :conn, :target_id]
  defstruct [:browser, :conn, :target_id]

  @type t :: %__MODULE__{browser: pid(), conn: pid(), target_id: String.t()}

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

    case Connection.call(page.conn, "Page.navigate", %{"url" => url}, timeout) do
      {:ok, %{"errorText" => error}} -> {:error, {:navigate, error}}
      {:ok, _result} -> await_navigation(page, wait_until, timeout)
      {:error, _} = error -> error
    end
  end

  defp await_navigation(page, :none, _timeout), do: {:ok, page}

  defp await_navigation(page, wait_until, timeout) do
    name = lifecycle_name(wait_until)

    case Connection.await_event(page.conn, &(&1["name"] == name), timeout) do
      :ok ->
        {:ok, page}

      {:error, :timeout} ->
        # The page just didn't signal readiness in time — navigation was still
        # issued, so return the page (best-effort), as documented.
        Logger.debug("[CDPEx.Page] readiness wait (#{name}) timed out; returning best-effort")
        {:ok, page}

      {:error, reason} ->
        # The connection died during navigation (:noproc / {:ws_closed, _}).
        # Surface it instead of returning a stale page handle as success.
        {:error, reason}
    end
  end

  defp lifecycle_name(:load), do: "load"
  defp lifecycle_name(_), do: "networkAlmostIdle"

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
      :none ->
        :ok

      wait_until ->
        name = lifecycle_name(wait_until)
        timeout = Keyword.get(opts, :timeout, @navigate_timeout)
        Connection.await_event(page.conn, &(&1["name"] == name), timeout)
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

    case Connection.call(page.conn, "Runtime.evaluate", params, timeout) do
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
  Polls until `css` matches an element, or `timeout` elapses.

  Returns `:ok` or `{:error, :timeout}`. Options: `:timeout` (default 5_000),
  `:interval` (poll interval ms, default 100).
  """
  @spec wait_for_selector(t(), String.t(), keyword()) :: :ok | {:error, term()}
  def wait_for_selector(%__MODULE__{} = page, css, opts \\ []) when is_binary(css) do
    wait_for_function(page, "document.querySelector(#{Jason.encode!(css)}) !== null", opts)
  end

  @doc """
  Polls a JavaScript expression until it is truthy, or `timeout` elapses.

  The expression is coerced with `!!(...)`, so JS truthiness applies. Returns
  `:ok` or `{:error, :timeout}`. Options: `:timeout` (default 5_000),
  `:interval` (poll interval ms, default 100).
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

  Returns `{:ok, png_binary}`, or `{:ok, path}` when `:path` is given (the file
  is written and the path returned).

  Options: `:path` (write to file), `:full_page` (capture beyond the viewport,
  default `false`), `:timeout` (default 30_000).
  """
  @spec screenshot(t(), keyword()) :: {:ok, binary()} | {:error, term()}
  def screenshot(%__MODULE__{} = page, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @screenshot_timeout)

    params = maybe_full_page(%{"format" => "png"}, Keyword.get(opts, :full_page, false))

    with {:ok, %{"data" => base64}} <-
           Connection.call(page.conn, "Page.captureScreenshot", params, timeout),
         {:ok, bytes} <- decode_screenshot(base64) do
      write_or_return(bytes, Keyword.get(opts, :path))
    end
  end

  defp maybe_full_page(params, true), do: Map.put(params, "captureBeyondViewport", true)
  defp maybe_full_page(params, false), do: params

  defp decode_screenshot(base64) do
    case Base.decode64(base64) do
      {:ok, bytes} -> {:ok, bytes}
      :error -> {:error, :invalid_screenshot_data}
    end
  end

  defp write_or_return(bytes, nil), do: {:ok, bytes}

  defp write_or_return(bytes, path) do
    case File.write(path, bytes) do
      :ok -> {:ok, path}
      {:error, reason} -> {:error, {:write_failed, reason}}
    end
  end
end
