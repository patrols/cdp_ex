defmodule CDPEx.MixProject do
  use Mix.Project

  @version "0.4.0"
  @source_url "https://github.com/patrols/cdp_ex"

  def project do
    [
      app: :cdp_ex,
      version: @version,
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      aliases: aliases(),
      dialyzer: dialyzer(),
      # Hex
      description: description(),
      package: package(),
      # Docs
      name: "CDPEx",
      source_url: @source_url,
      docs: docs()
    ]
  end

  # It's a library: no `mod:` — callers start CDPEx.Browser under their own
  # supervisor (or via CDPEx.launch/1).
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Run the `test` step of the `ci` alias under MIX_ENV=test. Without this, the
  # alias invokes `mix test` while still in :dev and Mix aborts.
  def cli do
    [
      preferred_envs: [ci: :test]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # CDP wire layer: WebSocket over Mint (brings in :mint + :hpax). No hackney;
      # castore is not needed because CDP speaks ws:// to localhost (no TLS).
      {:mint_web_socket, "~> 1.0"},
      # JSON-RPC encoding/decoding for the CDP protocol.
      {:jason, "~> 1.4"},
      # Observability: CDPEx emits :telemetry span/execute events (attaches no handlers).
      {:telemetry, "~> 1.2"},

      # Dev/test tooling
      {:ex_doc, "~> 0.34", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      # Style enforcer; runs as a `mix format` plugin (see .formatter.exs).
      {:styler, "~> 1.11", only: [:dev, :test], runtime: false},
      # Audits the locked dep tree against known security advisories (`mix deps.audit`).
      {:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false}
    ]
  end

  defp aliases do
    [
      # Mirrors the parent project's `mix ci`. `test --exclude integration` keeps
      # the default CI lane Chrome-free; the real-browser tests are tagged
      # `:integration` and run in a separate job that installs Chrome.
      ci: [
        "format --check-formatted",
        "deps.unlock --check-unused",
        "deps.audit",
        "compile --warnings-as-errors",
        # Build docs with warnings-as-errors so broken/typo'd doc references
        # (e.g. a type linked as `Mod.t/0` instead of `t:Mod.t/0`) fail CI before
        # they can reach a release. ex_doc must load in :test for this (see deps).
        "docs --warnings-as-errors",
        "credo",
        "dialyzer",
        "test --exclude integration"
      ]
    ]
  end

  defp dialyzer do
    [
      # The one known Mint opaque-type false positive is suppressed inline via
      # `@dialyzer {:nowarn_function, init: 1}` in CDPEx.Connection.
      # Keep PLTs outside _build so CI can cache them independently of dep rebuilds.
      plt_local_path: "priv/plts",
      plt_core_path: "priv/plts",
      flags: [
        :error_handling,
        :extra_return,
        :missing_return,
        :unmatched_returns,
        :unknown
      ]
    ]
  end

  defp description do
    "OTP-native Chrome DevTools Protocol (CDP) browser automation for Elixir. " <>
      "Launch headless Chrome and drive it over a Mint.WebSocket connection — " <>
      "no ChromeDriver, no Node.js."
  end

  defp package do
    [
      name: "cdp_ex",
      licenses: ["MIT"],
      maintainers: ["Patrick Olsen"],
      links: %{
        "GitHub" => @source_url,
        "Changelog" => @source_url <> "/blob/main/CHANGELOG.md"
      },
      files: ~w(lib mix.exs README.md CHANGELOG.md LICENSE .formatter.exs)
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      source_url: @source_url,
      extras: ["README.md", "CHANGELOG.md", "LICENSE"]
    ]
  end
end
