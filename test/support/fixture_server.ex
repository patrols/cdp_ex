defmodule CDPEx.FixtureServer do
  @moduledoc false
  # A tiny, dependency-free HTTP/1.1 server that serves a single fixed HTML page.
  #
  # Integration tests navigate Chrome here instead of using `data:` URLs: a real
  # http:// origin gives a stable `Runtime` execution context and a proper paint
  # surface, so `Runtime.evaluate`, lifecycle events, and `Page.captureScreenshot`
  # all behave normally (data: URLs flake on all three in headless Chrome).
  #
  #     {:ok, %{url: url}} = FixtureServer.start()
  #     CDPEx.Page.navigate(page, url)

  alias CDPEx.HttpFixture

  @spec start(keyword()) :: {:ok, %{port: non_neg_integer(), url: String.t()}}
  def start(opts \\ []) do
    # `:json_version` selects the /json/version variant the connect-discovery tests
    # exercise: :ok (default), :no_key, :non_string, :with_query, :server_error.
    json_version = Keyword.get(opts, :json_version, :ok)
    {:ok, listen} = :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)
    pid = spawn_link(fn -> accept_loop(listen, json_version) end)
    _ = :gen_tcp.controlling_process(listen, pid)
    {:ok, %{port: port, url: "http://127.0.0.1:#{port}/"}}
  end

  defp accept_loop(listen, json_version) do
    case :gen_tcp.accept(listen) do
      {:ok, socket} ->
        spawn(fn -> serve(socket, json_version) end)
        accept_loop(listen, json_version)

      {:error, :closed} ->
        :ok
    end
  end

  # :hang accepts the request then holds the socket without responding, so a client
  # with a short discovery timeout trips :discovery_timeout deterministically.
  defp serve(socket, :hang) do
    _ = HttpFixture.recv_request(socket)
    Process.sleep(2_000)
    :gen_tcp.close(socket)
  end

  defp serve(socket, json_version) do
    # Read the full request headers (they may arrive across TCP segments) so the
    # header reflection and auth check are deterministic, then respond.
    request = HttpFixture.recv_request(socket)
    _ = :gen_tcp.send(socket, respond(request, json_version))
    :gen_tcp.close(socket)
  end

  @basic_auth "Basic " <> Base.encode64("cdpex:secret")

  # Path routing:
  #   /basic-auth — gates on HTTP Basic credentials (cdpex:secret): without a valid
  #     Authorization header it answers 401 + WWW-Authenticate, so Chrome — and an armed
  #     CDPEx.Page.authenticate — receives an auth challenge.
  #   /redirect   — 302 to "/", so navigate(response: true) can prove it reports the
  #     FINAL (post-redirect) 200, not the redirect hop.
  #   /missing    — a genuine 404 (with a body, so Chrome still paints it).
  #   /data       — a tiny XHR/fetch target (the #fetch-btn calls it), for the
  #     wait_for_response/3 and wait_for_network_idle/2 paths.
  #   anything else serves the page.
  defp respond(request, json_version) do
    path = request_path(request)

    cond do
      String.starts_with?(path, "/basic-auth") and not authorized?(request) ->
        body = ~s(<!doctype html><html><body><p id="status">401</p></body></html>)

        HttpFixture.http_response("401 Unauthorized", body, [
          "WWW-Authenticate: Basic realm=\"cdpex\""
        ])

      String.starts_with?(path, "/redirect") ->
        HttpFixture.http_response("302 Found", "", ["Location: /"])

      String.starts_with?(path, "/missing") ->
        body = ~s(<!doctype html><html><body><p id="status">404</p></body></html>)
        HttpFixture.http_response("404 Not Found", body)

      String.starts_with?(path, "/data") ->
        HttpFixture.http_response("200 OK", "fetched-data")

      String.starts_with?(path, "/json/version") ->
        json_version_response(json_version)

      true ->
        HttpFixture.http_response("200 OK", render(request))
    end
  end

  @json_ct ["Content-Type: application/json"]

  # The host/port in the returned ws URL are deliberately bogus (127.0.0.1:1):
  # CDPEx.Connect must rewrite them to the endpoint's host/port, keeping only the
  # discovered path (and query).
  defp json_version_response(:no_key),
    do: HttpFixture.http_response("200 OK", ~s({"browser":"Chrome/1.0"}), @json_ct)

  defp json_version_response(:non_string),
    do: HttpFixture.http_response("200 OK", ~s({"webSocketDebuggerUrl":123}), @json_ct)

  defp json_version_response(:with_query) do
    body = ~s({"webSocketDebuggerUrl":"ws://127.0.0.1:1/devtools/browser/GUID?token=abc"})
    HttpFixture.http_response("200 OK", body, @json_ct)
  end

  defp json_version_response(:server_error),
    do: HttpFixture.http_response("500 Internal Server Error", "boom")

  # > 1 MB body, to trip CDPEx.Connect's @max_body_bytes cap (content is irrelevant —
  # the cap fires before the body is parsed).
  defp json_version_response(:oversized),
    do: HttpFixture.http_response("200 OK", String.duplicate("x", 1_100_000), @json_ct)

  defp json_version_response(_ok) do
    body = ~s({"webSocketDebuggerUrl":"ws://127.0.0.1:1/devtools/browser/FAKE-GUID"})
    HttpFixture.http_response("200 OK", body, @json_ct)
  end

  defp authorized?(request), do: HttpFixture.header_value(request, "authorization") == @basic_auth

  defp request_path(request) do
    request |> String.split("\r\n", parts: 2) |> hd() |> String.split(" ") |> Enum.at(1, "/")
  end

  # Reflects the X-CDPEx-Test request header into #echo-header so integration
  # tests can assert that extra headers were actually sent on the request.
  defp render(request) do
    echo = html_escape(HttpFixture.header_value(request, "x-cdpex-test"))

    """
    <!doctype html>
    <html>
      <head><title>CDPEx Fixture</title></head>
      <body>
        <h1 id="greeting">Hello</h1>
        <button id="btn" onclick="document.getElementById('greeting').textContent = 'Clicked'">Go</button>
        <button id="fetch-btn" onclick="fetch('/data').then(r => r.text()).then(t => { document.getElementById('greeting').textContent = t; })">Fetch</button>
        <button id="redirect-fetch-btn" onclick="fetch('/redirect')">RedirectFetch</button>
        <input id="name" oninput="document.getElementById('typed').textContent = this.value" />
        <div id="typed"></div>
        <button id="trusted-btn" onclick="document.getElementById('greeting').textContent = event.isTrusted ? 'trusted' : 'untrusted'">Trusted?</button>
        <button id="hidden-btn" style="display:none">Hidden</button>
        <form id="search-form" onsubmit="document.getElementById('greeting').textContent = 'submitted'; return false;">
          <input id="search" />
        </form>
        <div id="echo-header">#{echo}</div>
        <!-- Elements for the wait_for_selector attribute-prefix / quote-handling tests. -->
        <div id="ticket-card-abc">card-abc</div>
        <div id="ticket-card-def">card-def</div>
        <div data-name="foo bar">named</div>
        <div data-label="a'b">named-quote</div>
      </body>
    </html>
    """
  end

  defp html_escape(value) do
    value
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end
end
