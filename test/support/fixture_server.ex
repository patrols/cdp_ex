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

  @spec start() :: {:ok, %{port: non_neg_integer(), url: String.t()}}
  def start do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)
    pid = spawn_link(fn -> accept_loop(listen) end)
    _ = :gen_tcp.controlling_process(listen, pid)
    {:ok, %{port: port, url: "http://127.0.0.1:#{port}/"}}
  end

  defp accept_loop(listen) do
    case :gen_tcp.accept(listen) do
      {:ok, socket} ->
        spawn(fn -> serve(socket) end)
        accept_loop(listen)

      {:error, :closed} ->
        :ok
    end
  end

  defp serve(socket) do
    # Read the full request headers (they may arrive across TCP segments) so the
    # header reflection is deterministic, then respond.
    request = recv_request(socket, "")
    body = render(request)

    response =
      "HTTP/1.1 200 OK\r\n" <>
        "Content-Type: text/html; charset=utf-8\r\n" <>
        "Content-Length: #{byte_size(body)}\r\n" <>
        "Connection: close\r\n\r\n" <> body

    _ = :gen_tcp.send(socket, response)
    :gen_tcp.close(socket)
  end

  # Reflects the X-CDPEx-Test request header into #echo-header so integration
  # tests can assert that extra headers were actually sent on the request.
  defp render(request) do
    echo = html_escape(header_value(request, "x-cdpex-test"))

    """
    <!doctype html>
    <html>
      <head><title>CDPEx Fixture</title></head>
      <body>
        <h1 id="greeting">Hello</h1>
        <button id="btn" onclick="document.getElementById('greeting').textContent = 'Clicked'">Go</button>
        <div id="echo-header">#{echo}</div>
      </body>
    </html>
    """
  end

  defp header_value(request, name) do
    request
    |> String.split("\r\n")
    |> Enum.find_value("", &match_header(&1, name))
  end

  defp match_header(line, name) do
    case String.split(line, ":", parts: 2) do
      [k, v] -> if String.downcase(String.trim(k)) == name, do: String.trim(v)
      _ -> nil
    end
  end

  # Read until the end-of-headers marker (or a sane cap), so a request split
  # across TCP segments still yields the full headers for reflection.
  defp recv_request(socket, acc) do
    cond do
      String.contains?(acc, "\r\n\r\n") ->
        acc

      byte_size(acc) > 65_536 ->
        acc

      true ->
        case :gen_tcp.recv(socket, 0, 5_000) do
          {:ok, data} -> recv_request(socket, acc <> data)
          _ -> acc
        end
    end
  end

  defp html_escape(value) do
    value
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end
end
