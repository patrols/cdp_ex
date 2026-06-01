# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres
to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- `CDPEx.Page.wait_for_navigation/2` — await a navigation lifecycle milestone without issuing a navigation (e.g. after a click that navigates).
- `CDPEx.Page.wait_for_function/3` — poll a JavaScript expression until it is truthy.
- `CDPEx.Page.text/3`, `attribute/4`, `visible?/3` — element text / attribute / visibility helpers.
- `CDPEx.Page.cookies/2`, `set_cookies/3`, `clear_cookies/2` — cookie get / set / clear (lazily enables the `Network` domain).
- `CDPEx.Page.set_extra_headers/3`, `set_user_agent/3` — extra HTTP headers and User-Agent override.
- `CDPEx.Page.set_viewport/4` — viewport / device-metrics emulation.
- `CDPEx.Page.pdf/2` — render the page to PDF (`Page.printToPDF`); returns bytes or writes to `:path`.
- `CDPEx.Page.call_function/4` — call a JS function with JSON-serialized arguments.

## [0.1.0] - 2026-06-01

### Added
- Initial OTP-native Chrome DevTools Protocol client.
- `CDPEx.launch/1` and `CDPEx.stop/1` — supervised headless Chrome lifecycle.
- `CDPEx.new_page/2`, `CDPEx.close_page/2`, `CDPEx.with_page/3`.
- `CDPEx.Page`: `navigate/3`, `wait_for_selector/3`, `evaluate/3`, `click/3`,
  `html/2`, `screenshot/2`.

[Unreleased]: https://github.com/patrols/cdp_ex/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/patrols/cdp_ex/releases/tag/v0.1.0
