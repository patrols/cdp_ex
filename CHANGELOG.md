# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres
to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Initial OTP-native Chrome DevTools Protocol client.
- `CDPEx.launch/1` and `CDPEx.stop/1` — supervised headless Chrome lifecycle.
- `CDPEx.new_page/2`, `CDPEx.close_page/2`, `CDPEx.with_page/3`.
- `CDPEx.Page`: `navigate/3`, `wait_for_selector/3`, `evaluate/3`, `click/3`,
  `html/2`, `screenshot/2`.

[Unreleased]: https://github.com/patrols/cdp_ex/commits/main
