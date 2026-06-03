# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres
to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.3.0] - 2026-06-03

### Added
- `CDPEx.Pool` — a fixed-size pool of reusable browsers (`checkout/2`, `checkin/2`, `with_browser/3`, `with_page/3`) that keeps Chrome warm so a per-job fetch avoids a cold launch. Lazy launch up to `:size`, blocking checkout with timeout, automatic reclaim of a crashed caller's browser, and on-demand relaunch of a crashed one.
- `CDPEx.Page.observe_network/2`, `stop_observing_network/2`, and `response_body/3` — observe a page's network traffic (subscribe the caller to `Network.requestWillBeSent` / `responseReceived` events) and fetch a response body by requestId. Builds on the existing event-subscription machinery and the lazy `Network.enable`.
- `CDPEx.Page.authenticate/4` — answer proxy (`--proxy-server`) or HTTP Basic auth challenges with credentials, so authenticated proxies and Basic-auth-gated origins work. Backed by a per-page `CDPEx.Fetch` handler that enables the `Fetch` domain, auto-continues paused requests, and answers `authRequired` (with a `:source` filter and a bad-credentials loop guard). Supported on `:dedicated` pages only — a `:session` page returns `{:error, {:unsupported_transport, :session}}` (its handler would outlive the shared connection); an unknown `:source` returns `{:error, {:invalid_source, value}}`. Authenticating a page from another browser (or an already-closed one) returns `{:error, :unknown_page}`, and re-arming an already-authenticated page returns `{:error, :already_authenticated}`.
- `CDPEx.Page` request interception — `enable_request_interception/2` / `disable_request_interception/2` pause matching requests (delivering `Fetch.requestPaused` to the calling process), each resolved with `continue_request/3` (optionally rewriting url/method/headers/post-data), `fulfill_request/3` (a synthetic response), or `fail_request/3` (an error reason; unknown reasons return `{:error, {:invalid_error_reason, value}}`). Event-driven like `observe_network/2`; mutually exclusive with `authenticate/4` per page (both drive the `Fetch` domain).
- `t:CDPEx.error_reason/0` — a documented (best-effort) type of the `{:error, reason}` shapes CDPEx returns, so consumers know which tagged kinds to match. Not closed/exhaustive — kinds like `{:cdp_error, method, payload}` wrap open data.

### Breaking
- **Error-reason shapes normalized toward tagged tuples** (#20). A reason shape is a public contract — a matcher on the old bare atom silently falls through its catch-all with no compile/Dialyzer warning, so update any matchers:
  - `CDPEx.Connection.await_event/4` timeout: `{:error, :timeout}` → `{:error, {:timeout, :await_event}}`, sharing the `{:timeout, _}` shape with `call/5`'s `{:timeout, method}`.
  - A malformed `DevToolsActivePort` at launch: `{:error, :devtools_file_malformed}` → `{:error, {:devtools_file_malformed, excerpt}}`, carrying the file's contents excerpt like its sibling `{:debug_url_not_found, _}`.
  - Base64 validation failures now carry the offending data: `CDPEx.Page.response_body/3` returns `{:error, {:invalid_response_body, excerpt}}` (was `:invalid_response_body`), `CDPEx.Page.pdf/2` returns `{:error, {:invalid_pdf_data, excerpt}}` (was `:invalid_pdf_data`), and `CDPEx.Page.screenshot/2` returns `{:error, {:invalid_screenshot_data, excerpt}}` (was `:invalid_screenshot_data`) when Chrome sends a body / PDF / screenshot that isn't decodable base64.
  - **Unchanged (still bare, intentional):** `:noproc`; the high-level "didn't happen in time" `:timeout` from `CDPEx.Page` `wait_for_*` and `CDPEx.Pool.checkout/2`; and the control-flow outcomes `:unknown_page` / `:already_authenticated` — self-describing states with no payload to carry.

### Changed
- `CDPEx.Page.navigate/3` and `wait_for_navigation/2` raise `ArgumentError` on an unknown `:wait_until` value instead of silently treating it as `:network_almost_idle`.

### Fixed
- `CDPEx.Page.wait_for_navigation/2` now waits via the same lifecycle machinery as `navigate/3` (subscribe-before-wait, scoped to the page's session and the `Page.lifecycleEvent` method) rather than a generic event matcher — so it can no longer be falsely resolved by another event method whose params happen to carry a matching `"name"`.

## [0.2.2] - 2026-06-02

### Added
- Documented `:launch_timeout` as a ceiling (not a fixed wait) on `CDPEx.launch/1` and `CDPEx.with_page/3`, plus a "Running in containers" README section (timeout tuning, the fresh-profile cold-start cost, `/dev/shm` sizing, `--remote-allow-origins`).

### Changed
- Chrome readiness is now **polled**: `CDPEx.Chrome` checks the `DevToolsActivePort` file throughout the wait (not only at the deadline), so launch returns as soon as Chrome is reachable and `:launch_timeout` acts as a ceiling rather than a fixed cost — robust to Chrome builds that don't print the `DevTools listening on ws://…` stderr line.
- A launch that never exposes the DevTools endpoint now returns `{:error, {:debug_url_not_found, stderr_excerpt}}` (was the bare atom `:debug_url_not_found`), carrying Chrome's captured stderr so the failure is self-diagnosing. **Migration:** code matching the bare `:debug_url_not_found` atom (e.g. a retry classifier) must match `{:debug_url_not_found, _}` instead, or that error silently stops matching.
- `CDPEx.with_page/3`, given launch options, now contains a throwaway-browser crash: it returns `{:error, reason}` instead of letting the browser's linked exit propagate to and kill the caller. It briefly traps exits in the calling process for the duration of the call (see the `with_page/3` docs for the foreign-EXIT caveat and escape hatch).

### Fixed
- `CDPEx.Connection` no longer ignores an owning-process exit that arrives during the WebSocket upgrade — it aborts the connect at once instead of lingering until the upgrade timeout.
- `CDPEx.Connection` now stops when a WebSocket **pong** write fails (mirroring a failed command write), rather than continuing on a dead socket until the next command notices.
- `CDPEx.Page.navigate/3` prefers a just-arrived connection `:DOWN` over a best-effort readiness timeout when the two tie at the deadline, so a connection death surfaces as an error rather than a stale `{:ok, page}`.
- `CDPEx.Browser` no longer leaks Chrome if the browser connection drops in the window between connecting and its first subscribe — the init-time exit is caught and Chrome is reaped.
- `CDPEx.Chrome` launch-failure cleanup waits for the OS process to exit before removing the temp profile (matching `stop/1`), closing a `kill`/`rm` race.
- `CDPEx.Connection.call/5` and `await_event/4` return the documented timeout tuple instead of crashing the caller if the outer `GenServer.call` deadline fires first under scheduler starvation.
- `CDPEx.Connection` accumulates WebSocket upgrade headers across response chunks instead of replacing them (defensive; dormant for single-response `101` upgrades).

## [0.2.1] - 2026-06-02

### Changed
- `CDPEx.Browser` sets `shutdown: 10_000` in `child_spec/1` so a supervisor gives `terminate/2` enough time to reap Chrome.

### Fixed
- `CDPEx.Protocol.parse_ws_url/1` parses IPv6 hosts and raises a clear `ArgumentError` on a malformed URL (previously a `MatchError`).
- `CDPEx.Connection` no longer crashes when `call/5` / `await_event/4` is given a negative timeout (it fires immediately).
- `CDPEx.Connection` teardown fails in-flight callers with `{:error, {:ws_closed, _}}` instead of `{:error, :noproc}` on `close/1`.
- `CDPEx.Page.navigate/3` subscribes to lifecycle events before issuing the navigate, so a fast readiness event (e.g. `load` on a cached/local page) can no longer be dropped — a register-after-navigate race.

## [0.2.0] - 2026-06-02

### Added
- Opt-in `sessionId` multiplexing: `CDPEx.new_page(browser, transport: :session)` drives many pages over the one browser WebSocket (default `:dedicated` = one socket per page). `CDPEx.Connection.call/5` and `await_event/4` gain a `:session_id` option.
- `CDPEx.Page.wait_for_navigation/2` — await a navigation lifecycle milestone without issuing a navigation (e.g. after a click that navigates).
- `CDPEx.Page.wait_for_function/3` — poll a JavaScript expression until it is truthy.
- `CDPEx.Page.text/3`, `attribute/4`, `visible?/3` — element text / attribute / visibility helpers.
- `CDPEx.Page.cookies/2`, `set_cookies/3`, `clear_cookies/2` — cookie get / set / clear (lazily enables the `Network` domain).
- `CDPEx.Page.set_extra_headers/3`, `set_user_agent/3` — extra HTTP headers and User-Agent override.
- `CDPEx.Page.set_viewport/4` — viewport / device-metrics emulation.
- `CDPEx.Page.pdf/2` — render the page to PDF (`Page.printToPDF`); returns bytes or writes to `:path`.
- `CDPEx.Page.call_function/4` — call a JS function with JSON-serialized arguments.

### Changed
- A clean browser-connection close (its socket dropping, e.g. Chrome exiting) now stops `CDPEx.Browser` with a `:shutdown` reason rather than a crash reason — no spurious error report on expected teardown. Abnormal connection failures still surface loudly.

### Fixed
- `CDPEx.Connection.call/5` and `await_event/4` no longer crash the connection when given an `:infinity` timeout (which is valid per the `timeout()` spec).
- `CDPEx.Connection` now stops when its owning process exits, closing the socket even if the owner skipped its own teardown (e.g. a `:brutal_kill`).

## [0.1.0] - 2026-06-01

### Added
- Initial OTP-native Chrome DevTools Protocol client.
- `CDPEx.launch/1` and `CDPEx.stop/1` — supervised headless Chrome lifecycle.
- `CDPEx.new_page/2`, `CDPEx.close_page/2`, `CDPEx.with_page/3`.
- `CDPEx.Page`: `navigate/3`, `wait_for_selector/3`, `evaluate/3`, `click/3`,
  `html/2`, `screenshot/2`.

[Unreleased]: https://github.com/patrols/cdp_ex/compare/v0.3.0...HEAD
[0.3.0]: https://github.com/patrols/cdp_ex/compare/v0.2.2...v0.3.0
[0.2.2]: https://github.com/patrols/cdp_ex/compare/v0.2.1...v0.2.2
[0.2.1]: https://github.com/patrols/cdp_ex/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/patrols/cdp_ex/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/patrols/cdp_ex/releases/tag/v0.1.0
