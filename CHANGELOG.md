# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres
to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

[Unreleased]: https://github.com/patrols/cdp_ex/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/patrols/cdp_ex/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/patrols/cdp_ex/releases/tag/v0.1.0
