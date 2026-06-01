# Integration tests launch a real Chrome and are excluded by default. Run them
# with `mix test --include integration` (or `--only integration`) on a machine
# that has Chrome/Chromium available (set CDP_EX_CHROME_BINARY to point at it).
ExUnit.start(exclude: [:integration])
