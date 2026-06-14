defmodule CDPEx.Connect do
  @moduledoc false
  # Resolves a `CDPEx.connect/2` endpoint to a `ws://` or `wss://` browser URL. A
  # `ws(s)://` URL is used as-is; an `http(s)://` URL is discovered via
  # `GET /json/version`. The final URL's host/port come from the *endpoint*, not
  # the returned `webSocketDebuggerUrl`: Chrome echoes the request `Host` into that
  # field and can report `127.0.0.1`/localhost for a remote endpoint. The discovered
  # path AND query are kept (cloud browser providers carry an auth token in the query).

  # Chrome's /json/version endpoint is HTTP/1.1-only; using Mint.HTTP1 directly (vs
  # the Mint.HTTP facade) also keeps the conn a single opaque type, sidestepping a
  # `call_with_opaque` dialyzer false positive on the facade's struct union (OTP 26).
  alias CDPEx.Connection
  alias Mint.HTTP1

  # Overall ceiling for the whole /json/version exchange (not per-recv) and a hard cap
  # on the body, so a slow/dripping or flooding endpoint can't hang the caller or
  # exhaust memory. Chrome's real response is well under 1 KB.
  @discovery_timeout 5_000
  @max_body_bytes 1_048_576

  @spec resolve(String.t(), keyword()) ::
          {:ok, String.t()} | {:error, {:connect_discovery_failed, term()}}
  def resolve(endpoint, tls_opts \\ []) when is_binary(endpoint) do
    case URI.parse(endpoint) do
      %URI{scheme: s} when s in ["ws", "wss"] ->
        {:ok, endpoint}

      %URI{scheme: s, host: host, port: port} when s in ["http", "https"] and is_binary(host) ->
        discover(s, host, port, tls_opts)

      _ ->
        {:error, {:connect_discovery_failed, {:invalid_endpoint, endpoint}}}
    end
  end

  defp discover(scheme, host, port, tls_opts) do
    {transport, ws_scheme} = if scheme == "https", do: {:https, "wss"}, else: {:http, "ws"}
    deadline = System.monotonic_time(:millisecond) + @discovery_timeout

    with {:ok, conn} <- HTTP1.connect(transport, host, port, connect_opts(transport, tls_opts)),
         {:ok, conn, ref} <- request(conn),
         {:ok, status, body} <- recv_body(conn, ref, deadline),
         :ok <- check_status(status),
         {:ok, %{"webSocketDebuggerUrl" => url}} when is_binary(url) <- Jason.decode(body),
         %URI{path: path} = uri when is_binary(path) <- URI.parse(url) do
      {:ok, "#{ws_scheme}://#{host}:#{port}#{path}#{query_suffix(uri.query)}"}
    else
      {:error, reason} -> {:error, {:connect_discovery_failed, reason}}
      other -> {:error, {:connect_discovery_failed, other}}
    end
  end

  # https discovery honors the same TLS opts (:insecure / :cacertfile / :cacerts) the
  # caller passed to connect/2 — without this, a private-CA /json/version endpoint
  # would fail discovery even when the caller explicitly opted out of verification.
  # Mint adds SNI + hostname verification itself when verify == :verify_peer.
  defp connect_opts(:https, tls_opts),
    do: [mode: :passive, transport_opts: Connection.tls_opts(tls_opts)]

  defp connect_opts(_http, _tls_opts), do: [mode: :passive]

  # Issue the GET; on a request failure (after a successful connect) close the conn so
  # the socket isn't leaked. The happy path closes it in recv_body, and a failed
  # connect above never produced a conn.
  defp request(conn) do
    case HTTP1.request(conn, "GET", "/json/version", [], nil) do
      {:ok, conn, ref} ->
        {:ok, conn, ref}

      {:error, conn, reason} ->
        _ = HTTP1.close(conn)
        {:error, reason}
    end
  end

  defp check_status(status) when status in 200..299, do: :ok
  defp check_status(status), do: {:error, {:http_status, status}}

  # Drain the response under one absolute deadline (re-checked before each recv, so a
  # dripping endpoint can't extend it) with a body cap. Closes the conn on every exit.
  defp recv_body(conn, ref, deadline, status \\ nil, acc \\ []) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      _ = HTTP1.close(conn)
      {:error, :discovery_timeout}
    else
      drain(conn, ref, deadline, status, acc, remaining)
    end
  end

  defp drain(conn, ref, deadline, status, acc, remaining) do
    case HTTP1.recv(conn, 0, remaining) do
      {:ok, conn, responses} ->
        status = Enum.reduce(responses, status, &status_of(&1, ref, &2))
        acc = [acc | for({:data, ^ref, chunk} <- responses, do: chunk)]

        cond do
          IO.iodata_length(acc) > @max_body_bytes ->
            _ = HTTP1.close(conn)
            {:error, :discovery_body_too_large}

          Enum.any?(responses, &match?({:done, ^ref}, &1)) ->
            _ = HTTP1.close(conn)
            {:ok, status, IO.iodata_to_binary(acc)}

          true ->
            recv_body(conn, ref, deadline, status, acc)
        end

      {:error, conn, reason, _responses} ->
        _ = HTTP1.close(conn)
        {:error, reason}
    end
  end

  defp status_of({:status, ref, code}, ref, _acc), do: code
  defp status_of(_other, _ref, acc), do: acc

  defp query_suffix(nil), do: ""
  defp query_suffix(query), do: "?" <> query
end
