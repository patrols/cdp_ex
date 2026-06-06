defmodule CDPEx.ProxyAuthServer do
  @moduledoc false
  # A tiny, dependency-free HTTP forward proxy that REQUIRES Basic proxy
  # authentication — for exercising the `:proxy` auto-auth path end-to-end.
  #
  # Chrome launched with `--proxy-server=http://127.0.0.1:<port>` sends each
  # http:// request here in absolute-URI form (`GET http://host/path HTTP/1.1`).
  # Without a valid `Proxy-Authorization` header this answers `407` +
  # `Proxy-Authenticate: Basic`, which Chrome surfaces as a `Fetch.authRequired`
  # challenge with `source: "Proxy"`; an armed CDPEx proxy-auth handler answers it
  # with the configured credentials and Chrome retries authenticated. On a valid
  # header it serves a fixed HTML page — no real upstream forwarding, since the
  # point is the auth round-trip. A navigation to an otherwise non-resolvable host
  # (e.g. `http://proxied.test/`) therefore succeeds ONLY if the request actually
  # traversed the proxy and the 407 was answered.
  #
  #     {:ok, %{port: port}} = ProxyAuthServer.start(username: "u", password: "p")
  #     CDPEx.launch(proxy: "http://u:p@127.0.0.1:#{port}")

  alias CDPEx.HttpFixture

  @body ~s(<!doctype html><html><body><h1 id="greeting">Proxied</h1></body></html>)

  @spec start(keyword()) :: {:ok, %{port: non_neg_integer()}}
  def start(opts) do
    username = Keyword.fetch!(opts, :username)
    password = Keyword.fetch!(opts, :password)
    expected = "Basic " <> Base.encode64("#{username}:#{password}")

    {:ok, listen} = :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)
    pid = spawn_link(fn -> accept_loop(listen, expected) end)
    _ = :gen_tcp.controlling_process(listen, pid)
    {:ok, %{port: port}}
  end

  defp accept_loop(listen, expected) do
    case :gen_tcp.accept(listen) do
      {:ok, socket} ->
        spawn(fn -> serve(socket, expected) end)
        accept_loop(listen, expected)

      {:error, :closed} ->
        :ok
    end
  end

  defp serve(socket, expected) do
    request = HttpFixture.recv_request(socket)
    _ = :gen_tcp.send(socket, respond(request, expected))
    :gen_tcp.close(socket)
  end

  defp respond(request, expected) do
    if HttpFixture.header_value(request, "proxy-authorization") == expected do
      HttpFixture.http_response("200 OK", @body)
    else
      # 407 + a Basic challenge → Chrome emits Fetch.authRequired (source: Proxy).
      HttpFixture.http_response("407 Proxy Authentication Required", "", [
        "Proxy-Authenticate: Basic realm=\"cdpex-proxy\""
      ])
    end
  end
end
