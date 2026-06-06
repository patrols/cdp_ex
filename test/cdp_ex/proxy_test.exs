defmodule CDPEx.ProxyTest do
  use ExUnit.Case, async: true

  alias CDPEx.Proxy

  describe "parse/1 — URL form" do
    test "extracts scheme/host/port + credentials, stripping userinfo from the server" do
      assert {:ok, %{server: "http://host:8080", username: "user", password: "pass"}} =
               Proxy.parse("http://user:pass@host:8080")
    end

    test "credential-less URL parses with nil creds" do
      assert {:ok, %{server: "http://host:8080", username: nil, password: nil}} =
               Proxy.parse("http://host:8080")
    end

    test "preserves a non-http scheme (socks5)" do
      assert {:ok, %{server: "socks5://host:1080"}} = Proxy.parse("socks5://host:1080")
    end

    test "applies the default port for http/https" do
      assert {:ok, %{server: "http://host:80"}} = Proxy.parse("http://host")
      assert {:ok, %{server: "https://host:443"}} = Proxy.parse("https://host")
    end

    test "percent-decodes reserved characters in credentials" do
      assert {:ok, %{username: "u@ser", password: "p@ss:word"}} =
               Proxy.parse("http://u%40ser:p%40ss%3Aword@host:8080")
    end

    test "a username with no password yields a nil password" do
      assert {:ok, %{username: "user", password: nil}} = Proxy.parse("http://user@host:8080")
    end

    test "rejects a malformed/schemeless/portless URL" do
      assert {:error, {:invalid_proxy, _}} = Proxy.parse("host:8080")
      assert {:error, {:invalid_proxy, _}} = Proxy.parse("socks5://host")
      assert {:error, {:invalid_proxy, _}} = Proxy.parse("not a url")
    end

    test "wraps an IPv6 literal host in brackets in the server string" do
      assert {:ok, %{server: "http://[::1]:8080"}} = Proxy.parse("http://[::1]:8080")

      assert {:ok, %{server: "socks5://[2001:db8::1]:1080"}} =
               Proxy.parse("socks5://[2001:db8::1]:1080")
    end

    test "treats an empty username or password as absent (no auth, not a blank credential)" do
      assert {:ok, %{username: nil, password: "pass"}} = Proxy.parse("http://:pass@host:8080")
      assert {:ok, %{username: "user", password: nil}} = Proxy.parse("http://user:@host:8080")
    end
  end

  describe "parse/1 — keyword / map form" do
    test "builds the server from :server, defaulting the scheme to http" do
      assert {:ok, %{server: "http://host:8080", username: "u", password: "p"}} =
               Proxy.parse(server: "host:8080", username: "u", password: "p")
    end

    test "honours an explicit :scheme" do
      assert {:ok, %{server: "socks5://host:1080"}} =
               Proxy.parse(server: "host:1080", scheme: "socks5")
    end

    test "leaves a server that already carries a scheme untouched" do
      assert {:ok, %{server: "https://host:8443"}} = Proxy.parse(server: "https://host:8443")
    end

    test "takes credentials verbatim (no decoding) — the special-char-safe form" do
      assert {:ok, %{username: "u", password: "p@ss:word"}} =
               Proxy.parse(%{server: "host:8080", username: "u", password: "p@ss:word"})
    end

    test "rejects a missing/blank server" do
      assert {:error, {:invalid_proxy, _}} = Proxy.parse(username: "u", password: "p")
      assert {:error, {:invalid_proxy, _}} = Proxy.parse(server: "")
    end

    test "treats blank credentials as absent" do
      assert {:ok, %{username: nil, password: nil}} =
               Proxy.parse(server: "host:8080", username: "", password: "")
    end
  end

  describe "parse/1 — bad input" do
    test "rejects unsupported types" do
      assert {:error, {:invalid_proxy, _}} = Proxy.parse(123)
      assert {:error, {:invalid_proxy, _}} = Proxy.parse(nil)
    end
  end

  describe "to_arg/1 and credentials/1" do
    test "to_arg builds the --proxy-server flag" do
      {:ok, proxy} = Proxy.parse("http://host:8080")
      assert Proxy.to_arg(proxy) == "--proxy-server=http://host:8080"
    end

    test "credentials returns the pair only when both parts are present" do
      {:ok, with_creds} = Proxy.parse("http://u:p@host:8080")
      assert Proxy.credentials(with_creds) == %{username: "u", password: "p"}

      {:ok, no_creds} = Proxy.parse("http://host:8080")
      assert Proxy.credentials(no_creds) == nil

      {:ok, half} = Proxy.parse("http://u@host:8080")
      assert Proxy.credentials(half) == nil

      {:ok, empty_pass} = Proxy.parse("http://u:@host:8080")
      assert Proxy.credentials(empty_pass) == nil
    end
  end
end
