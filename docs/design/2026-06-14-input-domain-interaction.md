# Design: real Input-domain interaction (#72)

**Status:** approved (brainstorm) — pending implementation
**Target release:** 0.9.0 (breaking)
**Issue:** [#72](https://github.com/patrols/cdp_ex/issues/72)

## Context / problem

`CDPEx.Page.click/3` dispatches a synthetic DOM `.click()` via `Runtime.evaluate`
(`el.click()`), so `event.isTrusted` is `false` and there is no real hit-testing.
There is no keyboard / typing surface at all (zero `Input.*` usage). For a library
framed around scraping/automation this is the most visible gap — sites that gate on
trusted input can't be driven, and "fill a field, press Enter" isn't expressible.

This change introduces real `Input`-domain interaction: a trusted click plus
keyboard entry, replacing the synthetic click as the default.

## Decisions (resolved in brainstorm)

1. **`click/3` is trusted by default**, with a `trusted: false` escape hatch that
   keeps the old synthetic `el.click()`. Rationale: the default should be the
   correct behavior (the whole point of the issue); the synthetic path is still
   occasionally useful (fire a handler on an element not at a hittable point). The
   escape hatch may be **deprecated and removed in a future release** (removal is
   breaking, so it goes through a deprecation cycle, not a yank). It is documented
   as an escape hatch, not an equal alternative.
2. **Keyboard surface = `type/4` + `press/4`.** `type` uses `Input.insertText`
   (fast; fires `input`/`change`; no per-character `keydown`/`keyup`). `press`
   uses `Input.dispatchKeyEvent` for a curated set of named keys. Realistic
   per-character key events (a full keymap) are deferred — a future `type/4`
   `realistic:`/`delay:` option if demand appears.
3. **All functions live on `CDPEx.Page`** (consistent with the flat `Page.*` API;
   `click/3` already lives here so nothing moves). A dedicated `CDPEx.Input` /
   `Mouse` / `Keyboard` module is only warranted if low-level coordinate/raw-key
   primitives are added later — out of scope now.
4. **Click robustness = scroll-into-view + center-point click, with a tagged
   error** (no overlay hit-testing). `document.elementFromPoint` hit-test
   verification (Puppeteer-style) is deferred as future hardening.

## API surface (`CDPEx.Page`)

All calls are session-scoped — they go through the existing `do_call/4`
(`page.ex:1511` → `Connection.call(..., session_id:)`), so they work on both
`:dedicated` and `:session` transports.

- `click(page, css, opts \\ [])` :: `:ok | {:error, reason}`
  - Default (trusted): resolve `css` → `scrollIntoViewIfNeeded()` → read
    `getBoundingClientRect()` → `Input.dispatchMouseEvent` `mousePressed` then
    `mouseReleased` at the box center (`button: "left"`, `clickCount: 1`).
  - `trusted: false`: the current synthetic `el.click()`.
  - opts: `:trusted` (default `true`), `:timeout`.
- `type(page, css, text, opts \\ [])` :: `:ok | {:error, reason}`
  - Resolve `css` → `el.focus()` (JS) → `Input.insertText(%{"text" => text})`.
  - opts: `:timeout`.
- `press(page, css, key, opts \\ [])` :: `:ok | {:error, reason}`
  - When `css` is a selector: resolve → `el.focus()` → `Input.dispatchKeyEvent`
    `keyDown` then `keyUp` for `key`.
  - When `css` is `nil`: skip focus and press on the currently-focused element.
  - Single signature (a `nil` selector, not a separate 2-arity `press`) — avoids
    an arity-3 clash between `press(page, key, opts)` and `press(page, css, key)`.

### Supported `press` keys (curated keymap)

`Enter`, `Tab`, `Escape`, `Backspace`, `Delete`, `ArrowUp`, `ArrowDown`,
`ArrowLeft`, `ArrowRight`, `Home`, `End` — each mapped to the correct
`key` / `code` / `windowsVirtualKeyCode` so default actions fire (Enter submits a
form, Tab moves focus, etc.). An unsupported key name is a validation error.

## Error contract

Two new `t:CDPEx.error_reason/0` members, both classified `:terminal` (deterministic):

- `{:not_clickable, css}` — element matched but has no usable click box (zero-size
  / not visible even after scroll). Distinct from the existing
  `{:selector_not_found, css}` (no match at all).
- `{:unknown_key, key}` — `press` given a key outside the curated set.

Each requires, atomically (the compile-time coverage invariant, as in #75):
- a `classify_error/1` `:terminal` clause in `lib/cdp_ex.ex`, and
- an exemplar in the `@terminal` list in `test/cdp_ex_test.exs`.

`type` and `press` reuse `{:selector_not_found, css}` when the element isn't found.

## Implementation notes

- **One `evaluate` round-trip** for click-prep: a JS snippet does
  `querySelector` + null-check + `scrollIntoViewIfNeeded()` and returns
  `{found, x, y, w, h}` (or a sentinel for not-found / zero-box). Elixir then
  branches to the error tuples or dispatches the mouse events. Center is
  `x + w/2`, `y + h/2` — `getBoundingClientRect` and `Input.dispatchMouseEvent`
  both use CSS pixels, so no DPR conversion.
- `type`/`press` target via `el.focus()` rather than a trusted click, so they
  work even on elements a trusted click couldn't reach; the keystrokes are still
  real `Input` events.
- Reuse the visibility-check style already in `visible?/3` (`page.ex:726`).
- Keymap is a small module-level map (`%{"Enter" => %{...}, ...}`); lookup miss →
  `{:error, {:unknown_key, key}}`.

## Docs / release

- Rewrite the `click/3` `@doc` (trusted default + `trusted: false` escape hatch);
  add `type/4` and `press/4` docs.
- README: add `type`/`press` to the Page-operations table, update the `click`
  row, and remove the "synthetic click" warning from the Status callout (it's
  real now). Update the `#72` reference to point at shipped behavior.
- CHANGELOG `[Unreleased]`: `### Breaking` (click default now a trusted event;
  may newly error on off-screen/zero-box elements) + `### Added` (`type/4`,
  `press/4`). → **0.9.0**.

## Testing (real Chrome — extend `test/support/fixture_server.ex`)

Add to the fixture page: an `<input id="name">`, a button whose handler records
`event.isTrusted` (e.g. writes it into the DOM), and a `<form>` that submits on
Enter (visible effect on submit).

Integration (`@tag :integration`):
- trusted `click` → handler observes `isTrusted: true`.
- `click(trusted: false)` → handler observes `isTrusted: false` (escape hatch).
- `type` → input value set and `input` event fired.
- `press(…, "Enter")` on a form field → form submits.
- hidden / zero-box element → `{:error, {:not_clickable, _}}`.
- `selector_not_found` path unchanged.

Unit (no Chrome): keymap lookup; `{:unknown_key, _}`; the `error_reason/0`
coverage test gains the two new exemplars.

## Out of scope / future

- Overlay hit-test verification via `document.elementFromPoint` (D2).
- Realistic per-character typing (full keymap, `keydown`/`keyup` per char).
- Low-level primitives (raw-coordinate `mouse_move/3`, `key_down`/`key_up`) and a
  possible `CDPEx.Input` home for them.
- Deprecating/removing the `trusted: false` escape hatch.
