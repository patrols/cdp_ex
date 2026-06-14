# Design: connect to an existing/remote DevTools endpoint (#73)

**Status:** approved (brainstorm) — pending implementation
**Target release:** 0.9.0
**Issue:** [#73](https://github.com/patrols/cdp_ex/issues/73)

## Context / problem

cdp_ex can only `launch/1` a throwaway Chrome on the same host and reap it. It
cannot attach to a Chrome that is already running — a sidecar/remote Chrome
container, a cloud browser provider (Browserless / Browserbase), a warm
long-lived Chrome, or a real browser set up by hand. This is a standard capability
(Puppeteer `browserWSEndpoint`/`browserURL`, Playwright `connectOverCDP`) and was
the second functional gap flagged in the original review. It also re-enables
`wss://`, which 0.8.0 deliberately rejected (no consumer then; this PR is that
consumer).

Scope is held to a **`:session`-transport MVP**; dedicated-transport over a
remote browser is deferred (the per-page socket URL must target the remote host
and derive a `wss://` page URL — fiddly, low-demand).

## Decisions (resolved in brainstorm)

1. **Accept both endpoint forms.** A `ws://`/`wss://` URL connects directly; an
   `http://`/`https://` URL is discovered via `GET /json/version` →
   `webSocketDebuggerUrl`. The http form is the ergonomic default (you know
   `host:port`, not the per-launch GUID URL); the ws form is for TLS proxies /
   providers that hand you the socket URL.
2. **Teardown closes our targets, never Chrome.** `stop/1` on a connected browser
   `Target.closeTarget`s the pages cdp_ex opened (best-effort), then drops the
   socket; it never reaps Chrome and never touches pre-existing targets. Symmetric
   with `launch` (which owns Chrome) — `connect` owns only the targets it created.
3. **`:session` is the connected-browser default; explicit `:dedicated` errors.**
   `new_page/2` on a connected browser defaults to `:session` (rides the shared
   browser socket, works over remote/`wss://` as-is). `transport: :dedicated`
   returns `{:error, {:unsupported_transport, :dedicated}}` — no silent downgrade.
4. **TLS: verify by default via the OS trust store; escape hatches.** `wss://`
   verifies the peer cert using `:public_key.cacerts_get()` (OTP 25+; cdp_ex's
   floor is OTP 26) — **no new dependency** (preserving cdp_ex's dependency-light
   identity, vs. adding `castore`). `insecure: true` drops to `verify_none` for
   self-signed proxies; `cacertfile:`/`cacerts:` override the CA source.

## Public API (`CDPEx`)

- `connect(endpoint, opts \\ [])` :: `{:ok, browser} | {:error, term()}`
  - Returns the same Browser handle as `launch/1`; `new_page/2`, `with_page/3`,
    `close_page/2`, `stop/1` all work on it.
  - `endpoint`: `ws(s)://…` (direct) or `http(s)://host:port` (discovered).
  - opts: `:insecure` (bool, default `false`), `:cacertfile`, `:cacerts`, `:name`.
- `with_page(opts, fun, page_opts \\ [])` gains a connect route: when the keyword
  list contains `:connect`, it `connect`s a throwaway-handle browser for the call
  (page is closed and the socket dropped afterward; Chrome is never killed),
  otherwise it `launch`es as today.

## Internals

- `Browser.start_link([connect: endpoint] ++ opts)` — `init/1` detects `:connect`,
  **skips `Chrome.launch`**, resolves `endpoint` → ws URL, and calls
  `connect_browser/_` with **`chrome: nil`** + the resolved URL. The existing
  `connect_browser` already parses host/port, starts the `Connection`, and
  subscribes to `Target.detachedFromTarget`; its failure `catch` must guard
  `Chrome.stop(chrome)` for `nil`.
- **Endpoint resolution** (new private helper): ws/wss → passthrough; http/https →
  `Mint.HTTP` `GET /json/version`, `Jason`-decode, read `webSocketDebuggerUrl`.
  Any failure → `{:error, {:connect_discovery_failed, reason}}`.
  - **Host derivation:** Chrome echoes the request `Host` into the returned
    `webSocketDebuggerUrl` and can report `127.0.0.1`/`localhost` for a remote
    endpoint. So combine the **endpoint's host/port** with the **discovered URL's
    path** (the per-launch GUID), and carry the endpoint's `http→ws` /
    `https→wss` scheme — don't trust the returned host verbatim.
- **`CDPEx.Protocol.parse_ws_url/1`** re-accepts `wss://` and returns the scheme
  (`{scheme, host, port, path}`), reversing the 0.8.0 rejection.
- **`CDPEx.Connection.init/1`** selects `:http`/`:https` by scheme; for `wss`
  passes `transport_opts` (verify_peer + `:public_key.cacerts_get()` by default;
  `insecure`/`cacertfile`/`cacerts` from opts).
- **`Browser.new_page/2`** on a connected browser (`state.chrome == nil`):
  default `:session`; explicit `:dedicated` → `{:error, {:unsupported_transport, :dedicated}}`.
- **IPv6 fix** (carried from the #78 review): `open_target/_`'s page URL brackets
  an IPv6 host (`[::1]`) instead of `ws://::1:9222/…`. (Only reachable once
  dedicated-over-remote lands, but a cheap correctness fix.)

## Teardown

`terminate/2` / `stop/1`:
- `chrome != nil` (launched) — today's reap (kill Chrome, cleanup temp profile).
- `chrome == nil` (connected) — if `browser_conn` is alive, `Target.closeTarget`
  each tracked page/session (best-effort; ignore errors), then close the socket.
  Never reap Chrome. On a crashed/dropped connection there is nothing to close
  (the socket is gone) — just let go.

## Error reasons

- New `{:connect_discovery_failed, term()}` — `/json/version` GET or parse failed.
  Add to `t:CDPEx.error_reason/0`, `classify_error/1` → `:unknown`
  (payload-dependent: a network blip vs. a bad endpoint), and a coverage exemplar
  (in the `@payload_dependent` list in `test/cdp_ex_test.exs`).
- `:dedicated`-on-connected reuses the existing `{:unsupported_transport, term()}`.

## Testing

**Unit:**
- endpoint resolution: `ws://`/`wss://` passthrough; `http://` → discovery against
  a `/json/version` route added to `CDPEx.FixtureServer`; malformed/unreachable →
  `{:connect_discovery_failed, _}`.
- `parse_ws_url/1` accepts `wss://` and returns the scheme.
- `Connection` scheme → `:http`/`:https` selection (and TLS opt assembly) — unit,
  no real TLS server.
- `new_page(transport: :dedicated)` on a connected browser → error.

**Integration (real Chrome):**
- `launch` browser A (owns Chrome) → read its http endpoint
  (`:sys.get_state(A).host`/`port`) → `connect` browser B to `http://host:port` →
  `new_page(B, transport: :session)` → navigate + evaluate → `stop(B)` → **assert
  A's Chrome is still alive** (B still-open page closed; A unaffected). This is the
  no-reap guarantee, the key test.
- `with_page([connect: "http://host:port"], …)` smoke.

**Out of scope:** dedicated-transport over a connected browser; a `wss://`
integration test (needs a TLS-terminating proxy — the scheme/TLS selection is
unit-tested instead).

## Release

0.9.0. CHANGELOG `### Added` (`connect/2` + `with_page(connect:)`, `wss://`
support — noting the 0.8.0 rejection is lifted) and `### Fixed` (IPv6 page URL).

## Out of scope / future

- Dedicated transport over a connected/remote browser (per-page socket URL host +
  `wss://` page URL).
- `wss://` end-to-end integration test.
- A dedicated `disconnect/1` alias (Puppeteer familiarity) — `stop/1` covers it.
