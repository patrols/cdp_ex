# CDPEx

[![Hex.pm](https://img.shields.io/hexpm/v/cdp_ex.svg)](https://hex.pm/packages/cdp_ex)
[![Docs](https://img.shields.io/badge/hex-docs-purple.svg)](https://hexdocs.pm/cdp_ex)
[![CI](https://github.com/patrols/cdp_ex/actions/workflows/ci.yml/badge.svg)](https://github.com/patrols/cdp_ex/actions/workflows/ci.yml)
[![License](https://img.shields.io/hexpm/l/cdp_ex.svg)](https://github.com/patrols/cdp_ex/blob/main/LICENSE)

OTP-native [Chrome DevTools Protocol](https://chromedevtools.github.io/devtools-protocol/)
browser automation for Elixir. Launch headless Chrome and drive it directly over a
`Mint.WebSocket` connection — **no ChromeDriver, no Node.js**.

```elixir
CDPEx.with_page([], fn page ->
  {:ok, _} = CDPEx.Page.navigate(page, "https://example.com")
  CDPEx.Page.html(page)
end)
#=> {:ok, "<html>…</html>"}
```

## Why CDPEx?

It drives Chrome over CDP the way Puppeteer and Playwright do — but it's pure
Elixir: the browser and each page's CDP connection are **supervised OTP
processes** (a page is a lightweight handle over its connection). A Chrome crash
or a dropped socket surfaces to the caller as `{:error, reason}` instead of a
hung session, and `terminate/2` guarantees the OS process is reaped (no zombie
Chromes).

| | CDPEx | chrome_remote_interface | ChromicPDF | Wallaby |
|---|---|---|---|---|
| Transport | CDP (WebSocket) | CDP (WebSocket) | CDP (WebSocket) | WebDriver / ChromeDriver |
| Runtime deps | `mint_web_socket`, `jason` | `hackney` + others | a few | ChromeDriver process |
| Supervised lifecycle | ✅ | — | ✅ (PDF pool) | partial |
| Scope | general automation | low-level client | PDF / screenshots | testing |
| Node.js required | no | no | no | no |

If you want a small, dependency-light CDP client with proper OTP supervision — and
you don't want a ChromeDriver process or a Node sidecar — that's the gap CDPEx fills.

> #### Status {: .info}
>
> **Transports:** pages default to one WebSocket each (strong crash isolation).
> Opt into `sessionId` multiplexing — many pages over the one browser socket —
> with `new_page(browser, transport: :session)`; the trade-off is shared fate (a
> dropped browser connection drops all of its session pages).
>
> Connection pooling, network interception, and stealth remain out of scope for now.

## Installation

Add `cdp_ex` to your deps in `mix.exs`:

```elixir
def deps do
  [
    {:cdp_ex, "~> 0.1"}
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
`:checkout_timeout`) when all are busy. A caller that crashes returns its browser
automatically, and a crashed browser is relaunched on demand.

## Page operations

| Function | Description |
|---|---|
| `navigate/3` | Go to a URL, waiting for `networkAlmostIdle` (configurable) |
| `wait_for_selector/3` | Poll until a CSS selector matches |
| `evaluate/3` | Run JS and return the value (`returnByValue`) |
| `click/3` | Synthetic `.click()` on the first match |
| `html/2` | Full serialized DOM (`document.documentElement.outerHTML`) |
| `screenshot/2` | PNG bytes, or write to `:path` |
| `observe_network/2` | Stream `Network` request/response events to the caller |
| `response_body/3` | Fetch a response body by requestId (`Network.getResponseBody`) |

Full API: [hexdocs.pm/cdp_ex](https://hexdocs.pm/cdp_ex).

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

MIT — see [LICENSE](LICENSE).
