# CDPEx

OTP-native Chrome DevTools Protocol client, published on Hex as `cdp_ex`. Runtime
deps are `mint_web_socket` and `jason` only; adding a dependency is a public-API
decision, not a convenience. Its main consumer is Pulse (livein.city), which uses
it for all browser scraping. Design notes live in `docs/design/`.

## Commands

```bash
mix ci                                  # the gate: format, unused deps, deps.audit, compile + docs + tests with warnings-as-errors, credo, dialyzer
mix test                                # unit tests, no Chrome
mix test --only integration             # real Chrome; set CDP_EX_CHROME_BINARY
```

- `mix ci` excludes `:integration`, so a green `mix ci` says nothing about real
  browser behaviour. Run the integration tests for any change to launch,
  teardown, page, input, fetch/proxy, or connection code.
- CI runs `mix ci` on Elixir 1.15.8/OTP 26.2 **and** 1.19.5/OTP 28.1. Code must
  compile on 1.15: gate newer stdlib features at compile time the way
  `CDPEx.ProcessLabel` does for `Process.set_label/1` (1.17+).
- Dialyzer runs with `:unmatched_returns` and friends; PLTs live in `priv/plts`.

## Invariants

- **Every launched Chrome is reaped on every exit path** (normal return, raise,
  caller death, launch/exec error). This is the library's core promise; a change
  that can leave an OS process behind is a bug even if every test passes. After
  an ad-hoc `mix run` repro, check for orphans by parent — a ppid-1 Chrome with a
  `cdp_ex-*` profile is yours to `kill`.
- **The error taxonomy is closed.** A new `CDPEx.error_reason/0` member needs a
  classification in `CDPEx.classify_error/1` and an exemplar in
  `test/cdp_ex_test.exs`; the "error_reason/0 coverage" test fails otherwise.
  It checks type → classification only, so also confirm the code that *returns*
  the new reason matches the type.
- No anti-bot stealth is built in. #35 tracks optional presets, gated on
  evidence that a real site needs them; don't add evasion tweaks ad hoc.

## Git and PRs

- `main` requires **signed commits** and an up-to-date branch. Never use
  `gh pr update-branch --rebase` or the web "Update branch" button: GitHub
  rewrites the commits unsigned and the PR stays `BLOCKED` with every check
  green. Rebase locally and `git push --force-with-lease` instead.
- History is squash-merged. Merging two PRs back-to-back leaves the second one
  behind; expect one local rebase.
- Every user-visible change adds a line under `## [Unreleased]` in
  `CHANGELOG.md` (Keep a Changelog), ending with the PR number.

## Releasing

0.x minors may break the API, so the README pins the patch series (`~> 0.10.0`).
A release PR: promote `[Unreleased]` to `[x.y.z] - date`, bump `@version` in
`mix.exs`, bump the README install pin. After it merges, tag `vx.y.z` on main.
`mix hex.publish` prompts for a 2FA code and cannot run without a TTY — the
maintainer runs it. A `mix.lock`-only bump doesn't reach consumers (their own
lockfile resolves deps), so a security bump of a transitive dep needs no release
on its own.
