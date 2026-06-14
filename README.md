# CDPEx

[![Hex.pm](https://img.shields.io/hexpm/v/cdp_ex.svg)](https://hex.pm/packages/cdp_ex)
[![Docs](https://img.shields.io/badge/hex-docs-purple.svg)](https://hexdocs.pm/cdp_ex)
[![CI](https://github.com/patrols/cdp_ex/actions/workflows/ci.yml/badge.svg)](https://github.com/patrols/cdp_ex/actions/workflows/ci.yml)
[![License](https://img.shields.io/hexpm/l/cdp_ex.svg)](https://github.com/patrols/cdp_ex/blob/main/LICENSE)

OTP-native [Chrome DevTools Protocol](https://chromedevtools.github.io/devtools-protocol/)
browser automation for Elixir. Launch headless Chrome and drive it directly over a
`Mint.WebSocket` connection. **No ChromeDriver, no Node.js.**

```elixir
CDPEx.with_page([], fn page ->
  {:ok, _} = CDPEx.Page.navigate(page, "https://example.com")
  CDPEx.Page.html(page)
end)
#=> {:ok, "<html>…</html>"}
```

## Why CDPEx?

It drives Chrome over CDP the way Puppeteer and Playwright do, but in pure
Elixir: the browser and each page's CDP connection are **supervised OTP
processes** (a page is a lightweight handle over its connection). A Chrome crash
or a dropped socket surfaces to the caller as `{:error, reason}` instead of a
hung session, and `terminate/2` guarantees the OS process is reaped (no zombie
Chromes).

It's production-tested: it runs as the sole browser engine for a JavaScript-heavy
scraper, where it replaced a Wallaby/ChromeDriver setup.

| | CDPEx | chrome_remote_interface | ChromicPDF | Wallaby |
|---|---|---|---|---|
| Transport | CDP (WebSocket) | CDP (WebSocket) | CDP (WebSocket) | WebDriver / ChromeDriver |
| Runtime deps | `mint_web_socket`, `jason`, `telemetry` | `hackney` + others | a few | ChromeDriver process |
| Supervised lifecycle | ✅ | — | ✅ (PDF pool) | partial |
| Scope | general automation | low-level client | PDF / screenshots | testing |

If you want a small, dependency-light CDP client with proper OTP supervision, and
you'd rather not run a ChromeDriver process (like Wallaby) or a Node sidecar (like
Playwright or Puppeteer), that's the gap CDPEx fills.

> #### Status {: .info}
>
> **Transports:** pages default to one WebSocket each (strong crash isolation).
> Opt into `sessionId` multiplexing (many pages over the one browser socket)
> with `new_page(browser, transport: :session)`; the trade-off is shared fate (a
> dropped browser connection drops all of its session pages).
>
> **`click/3`** dispatches a synthetic DOM `.click()` (via `Runtime.evaluate`),
> not a trusted OS-level input event — it won't satisfy sites that gate on
> `event.isTrusted` or real hit-testing. Real `Input`-domain dispatch is tracked
> in [#72](https://github.com/patrols/cdp_ex/issues/72).
>
> Stealth / anti-fingerprinting presets remain out of scope for now (evidence-gated).

## Installation

Add `cdp_ex` to your deps in `mix.exs`:

```elixir
def deps do
  [
    {:cdp_ex, "~> 0.7.0"}
  ]
end
```

You also need Chrome or Chromium installed. CDPEx finds it via, in order: the
`:chrome_binary` option, `CDP_EX_CHROME_BINARY`, `CHROME_BINARY`, then an OS default.
For reproducible setups, point it at a
[Chrome for Testing](https://googlechromelabs.github.io/chrome-for-testing/) binary.

> #### Sandbox {: .warning}
>
> CDPEx launches Chrome with `--no-sandbox` by default, since the sandbox can't
> start in many CI/container environments. If you run as root or drive untrusted
> pages, re-enable it by overriding `:args` — see `CDPEx.Chrome`.

## Running in containers

CDPEx is validated on macOS, but its defaults already target Linux containers:
`--no-sandbox`, `--disable-dev-shm-usage`, and `--disable-setuid-sandbox` are on
by default, so headless Chrome starts out of the box on a constrained host (e.g.
2 vCPU / 2 GB). A few things smooth the path further:

- **Tune `:launch_timeout` for cold starts.** Chrome's first launch in a fresh
  container is slower than on a warm dev machine. `:launch_timeout` is a *ceiling*,
  not a fixed wait (readiness is polled and returns as soon as Chrome is
  reachable), so a generous value costs nothing on a fast launch:

  ```elixir
  CDPEx.launch(launch_timeout: 30_000)
  ```

- **Fresh-profile cost.** Each launch creates a new `--user-data-dir` (removed on
  stop), so there's no warm disk cache between launches and the *first* navigation
  pays a cold-start cost. For throughput, prefer one long-lived browser (`launch/1`
  + reuse) over a throwaway `with_page([...])` per request, or pass a persistent
  `:user_data_dir`.

- **`/dev/shm` sizing.** Docker defaults `/dev/shm` to 64 MB, which Chrome can
  exhaust (crashing tabs). CDPEx ships `--disable-dev-shm-usage` by default (Chrome
  writes to `/tmp` instead), so it works on a small `/dev/shm` as-is. To size it up
  instead (`--shm-size=1g`), drop that flag via a custom `:args`.

- **Memory.** On a 2 GB host a single browser with a few pages is comfortable; each
  open page and large screenshots/PDFs add transient memory. Close pages promptly,
  or use `transport: :session` to cut per-page socket/process overhead when you
  don't need crash isolation.

- **`--remote-allow-origins`.** Some Chrome builds enforce an `Origin` check on the
  DevTools WebSocket upgrade and may reject a CDP client with a 403. CDPEx doesn't
  set this by default; if you hit `{:error, {:ws_upgrade, _}}` at connect, add it:

  ```elixir
  CDPEx.launch(launch_timeout: 30_000, extra_args: ["--remote-allow-origins=*"])
  ```

## Usage

### Resource-safe (recommended)

`with_page/3` opens a page, runs your function, and always tears everything down —
even if the function raises:

```elixir
# Throwaway browser + page for one job:
{:ok, title} =
  CDPEx.with_page([], fn page ->
    {:ok, _} = CDPEx.Page.navigate(page, "https://example.com")
    CDPEx.Page.evaluate(page, "document.title")
  end)
```

### Explicit lifecycle

```elixir
{:ok, browser} = CDPEx.launch(headless: true)
{:ok, page}    = CDPEx.new_page(browser)

{:ok, _page} = CDPEx.Page.navigate(page, "https://example.com")
:ok          = CDPEx.Page.wait_for_selector(page, "h1")
{:ok, html}  = CDPEx.Page.html(page)
{:ok, "Example Domain"} = CDPEx.Page.evaluate(page, "document.querySelector('h1').textContent")
{:ok, _png}  = CDPEx.Page.screenshot(page, path: "example.png")

:ok = CDPEx.close_page(browser, page)
:ok = CDPEx.stop(browser)
```

### Under your supervision tree

Because `terminate/2` reaps Chrome, supervise the browser with a `:shutdown`
timeout (not `:brutal_kill`):

```elixir
children = [
  {CDPEx.Browser, name: MyBrowser, headless: true}
]
Supervisor.start_link(children, strategy: :one_for_one)
```

### Pooling

Reuse warm browsers instead of paying a cold launch per job with `CDPEx.Pool`:

```elixir
children = [
  {CDPEx.Pool, name: MyPool, size: 4, launch_opts: [headless: true]}
]
Supervisor.start_link(children, strategy: :one_for_one)

# Borrow a warm browser for one fetch (a pooled drop-in for with_page/3):
CDPEx.Pool.with_page(MyPool, fn page ->
  {:ok, _} = CDPEx.Page.navigate(page, "https://example.com")
  CDPEx.Page.html(page)
end)
```

Browsers launch lazily up to `:size` and are reused; `checkout/2` blocks (up to
`:checkout_timeout`) when all are busy. Launches are asynchronous, so the pool
stays responsive during a cold start and warms multiple browsers concurrently
under load. A caller that crashes returns its browser automatically, and a
crashed browser is relaunched on demand.

## Page operations

| Function | Description |
|---|---|
| `navigate/3` | Go to a URL, waiting for `networkAlmostIdle` (configurable) |
| `wait_for_selector/3` | Poll until a CSS selector matches |
| `wait_for_response/3` | Block until a network response URL matches (fn / `Regex` / substring) |
| `wait_for_network_idle/2` | Block until the network settles (Puppeteer "networkidle") |
| `evaluate/3` | Run JS and return the value (`returnByValue`) |
| `click/3` | Synthetic `.click()` on the first match |
| `html/2` | Full serialized DOM (`document.documentElement.outerHTML`) |
| `screenshot/2` | PNG bytes, or write to `:path` |
| `pdf/2` | Render the page to PDF bytes, or write to `:path` |
| `set_user_agent/3` | Override the UA string, with optional Client-Hints metadata + `Accept-Language` |
| `observe_network/2` | Stream `Network` request/response events to the caller |
| `response_body/3` | Fetch a response body by requestId (`Network.getResponseBody`) |
| `enable_request_interception/2` | Pause matching requests for the caller to resolve |
| `continue_request/3` / `fulfill_request/3` / `fail_request/3` | Resolve a paused request (proceed / synthetic response / fail) |
| `authenticate/4` | Answer a proxy / HTTP Basic auth challenge (call before `navigate/3`) |

Full API: [hexdocs.pm/cdp_ex](https://hexdocs.pm/cdp_ex).

## Recipes

End-to-end patterns for the event-driven features. Each `CDPEx.Page` function is
documented in full on [hexdocs](https://hexdocs.pm/cdp_ex/CDPEx.Page.html).

### Block or rewrite requests (interception)

Interception is event-driven: the process that enables it receives one
`Fetch.requestPaused` event per request and must resolve every one — with
`continue_request/3`, `fulfill_request/3`, or `fail_request/3`. Drive it from a single
long-lived process (an unresolved request stalls the page).

```elixir
defmodule ImageBlocker do
  # Drops image requests; lets everything else through.
  def run(page) do
    :ok = CDPEx.Page.enable_request_interception(page)
    loop(page)
  end

  defp loop(page) do
    receive do
      {:cdp_event, _conn, "Fetch.requestPaused", %{"requestId" => id, "request" => request}, _sid} ->
        if String.ends_with?(request["url"], [".png", ".jpg", ".webp"]) do
          CDPEx.Page.fail_request(page, id, reason: :blocked_by_client)
        else
          CDPEx.Page.continue_request(page, id)
        end

        loop(page)
    after
      1_000 -> :ok
    end
  end
end
```

### Grab an API response triggered by a click (SPA)

Arm the waiter *before* the action that fires the request. The matcher is a substring,
a `Regex`, or a `(url -> boolean)` function.

```elixir
CDPEx.with_page([], fn page ->
  {:ok, _} = CDPEx.Page.navigate(page, "https://example.com/app")

  waiter = Task.async(fn -> CDPEx.Page.wait_for_response(page, ~r{/api/items}) end)
  :ok = CDPEx.Page.click(page, "#load-more")

  {:ok, %{"requestId" => id, "response" => %{"status" => 200}}} = Task.await(waiter)
  CDPEx.Page.response_body(page, id)
end)
```

When you just need the page to settle after hydration (no specific response to match),
use `wait_for_network_idle/2` instead.

### Detect a 403 wall / 404 / login redirect

`navigate/3` returns `{:ok, page}` even for a 403 or a redirect-to-login. Pass
`response: true` to also get the main document's HTTP status and final (post-redirect)
URL:

```elixir
case CDPEx.Page.navigate(page, url, response: true) do
  {:ok, _page, %{status: 200, url: final_url}} -> {:landed, final_url}
  {:ok, _page, %{status: status}}              -> {:blocked, status}
  {:error, reason}                             -> {:error, reason}
end
```

### Authenticated proxy

Pass `:proxy` — CDPEx sets `--proxy-server` and answers the proxy's auth challenge on
each page automatically, so you just navigate:

```elixir
{:ok, browser} = CDPEx.launch(proxy: "http://user:pass@proxy.example.com:8080")
# keyword form avoids percent-encoding a special-char password:
# CDPEx.launch(proxy: [server: "proxy.example.com:8080", username: "u", password: "p@ss"])

CDPEx.with_page(browser, fn page ->
  {:ok, _} = CDPEx.Page.navigate(page, "https://example.com")
  CDPEx.Page.html(page)
end)
```

For a one-off HTTP Basic challenge on an *origin* (not a proxy), arm it per page with
`authenticate/4` before navigating:
`CDPEx.Page.authenticate(page, "user", "pass", source: :server)`.

## Error handling

Operations return `{:error, reason}` on failure. Rather than hard-code the reason
shapes, classify them to drive retries:

```elixir
case CDPEx.Page.navigate(page, url) do
  {:ok, page} ->
    {:ok, page}

  {:error, reason} ->
    if CDPEx.transient?(reason), do: retry(), else: {:error, reason}
end
```

`CDPEx.classify_error/1` buckets a reason as `:transient` (connection dropped or
couldn't be established, timeout, Chrome died or was slow to start, an internal helper
crashed, or a connection-layer `net::ERR_*` navigation error, so a fresh attempt may
succeed), `:terminal` (selector miss, JS exception, usage/validation error, which a
retry won't fix), or `:unknown` (payload-dependent, e.g. an ambiguous `net::ERR_*`
navigation error or a CDP error code; you decide). The library tracks the error surface, so the
transient/terminal decision lives in one place instead of drifting across callers.
The reason shapes are documented as
[`t:CDPEx.error_reason/0`](https://hexdocs.pm/cdp_ex/CDPEx.html#t:error_reason/0).

Retries are yours to bound: cap attempts, back off, and on a `:transient` result
re-establish the resource (open a fresh page/browser) rather than reusing a dead
handle — a dead page keeps returning `:noproc`.

## Telemetry

CDPEx emits [`:telemetry`](https://hexdocs.pm/telemetry) events and attaches no
handlers; attach your own to record them (emitting with nothing attached is a no-op).
Events: `[:cdp_ex, :launch, …]` and `[:cdp_ex, :navigate, …]` spans,
`[:cdp_ex, :page, :start | :stop]`, and `[:cdp_ex, :error]`. See
[`CDPEx.Telemetry`](https://hexdocs.pm/cdp_ex/CDPEx.Telemetry.html) for the full
taxonomy (measurements + metadata).

```elixir
:telemetry.attach(
  "cdp-nav",
  [:cdp_ex, :navigate, :stop],
  fn _event, %{duration: d}, %{url: url, status: status}, _config ->
    ms = System.convert_time_unit(d, :native, :millisecond)
    IO.puts("#{url} -> #{inspect(status)} in #{ms}ms")
  end,
  nil
)
```

`status` (and the post-redirect `final_url`) are `nil` unless the navigation used
`response: true` — see `CDPEx.Page.navigate/3`.

## Development

```bash
mix deps.get
mix test                         # unit tests (no Chrome needed)
mix test --include integration   # real-Chrome tests (set CDP_EX_CHROME_BINARY)
mix ci                           # format, credo, dialyzer, unit tests
```

Integration tests are tagged `:integration` and excluded by default; they launch a
real Chrome and drive it against a local fixture HTTP server.

## Acknowledgements

Built on [`mint_web_socket`](https://hex.pm/packages/mint_web_socket). Inspired by
the production CDP work in [ChromicPDF](https://github.com/bitcrowd/chromic_pdf) and
by Puppeteer's protocol layer.

## License

MIT. See [LICENSE](LICENSE).
