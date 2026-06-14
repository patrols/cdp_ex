defmodule CDPEx.Connect do
  @moduledoc false
  # Resolves a `CDPEx.connect/2` endpoint to a `ws://` or `wss://` browser URL. A
  # `ws(s)://` URL is used as-is; an `http(s)://` URL is discovered via
  # `GET /json/version`. The final URL's host/port come from the *endpoint*, not
  # the returned `webSocketDebuggerUrl`: Chrome echoes the request `Host` into that
  # field and can report `127.0.0.1`/localhost for a remote endpoint.

  # Chrome's /json/version endpoint is HTTP/1.1-only; using Mint.HTTP1 directly (vs
  # the Mint.HTTP facade) also keeps the conn a single opaque type, sidestepping a
  # `call_with_opaque` dialyzer false positive on the facade's struct union (OTP 26).
  alias Mint.HTTP1

  @discovery_timeout 5_000

  @spec resolve(String.t()) :: {:ok, String.t()} | {:error, {:connect_discovery_failed, term()}}
  def resolve(endpoint) when is_binary(endpoint) do
    case URI.parse(endpoint) do
      %URI{scheme: s} when s in ["ws", "wss"] ->
        {:ok, endpoint}

      %URI{scheme: s, host: host, port: port} when s in ["http", "https"] and is_binary(host) ->
        discover(s, host, port)

      _ ->
        {:error, {:connect_discovery_failed, {:invalid_endpoint, endpoint}}}
    end
  end

  defp discover(scheme, host, port) do
    transport = if scheme == "https", do: :https, else: :http
    ws_scheme = if scheme == "https", do: "wss", else: "ws"

    with {:ok, conn} <- HTTP1.connect(transport, host, port, mode: :passive),
         {:ok, conn, ref} <- HTTP1.request(conn, "GET", "/json/version", [], nil),
         {:ok, body} <- recv_body(conn, ref, []),
         {:ok, %{"webSocketDebuggerUrl" => discovered}} <- Jason.decode(body),
         %URI{path: path} when is_binary(path) <- URI.parse(discovered) do
      {:ok, "#{ws_scheme}://#{host}:#{port}#{path}"}
    else
      {:error, reason} -> {:error, {:connect_discovery_failed, reason}}
      {:error, _conn, reason} -> {:error, {:connect_discovery_failed, reason}}
      other -> {:error, {:connect_discovery_failed, other}}
    end
  end

  defp recv_body(conn, ref, acc) do
    case HTTP1.recv(conn, 0, @discovery_timeout) do
      {:ok, conn, responses} ->
        acc = acc ++ for({:data, ^ref, chunk} <- responses, do: chunk)

        if Enum.any?(responses, &match?({:done, ^ref}, &1)) do
          _ = HTTP1.close(conn)
          {:ok, IO.iodata_to_binary(acc)}
        else
          recv_body(conn, ref, acc)
        end

      {:error, _conn, reason, _responses} ->
        {:error, reason}
    end
  end
end
