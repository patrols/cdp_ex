defmodule CDPEx.HttpFixture do
  @moduledoc false
  # Shared HTTP/1.1 plumbing for the dependency-free test fixture servers
  # (`CDPEx.FixtureServer`, `CDPEx.ProxyAuthServer`): read a full request off a
  # raw socket, pull a header value, and build a `Connection: close` response.
  #
  # Kept deliberately tiny — just enough for a single request/response per socket,
  # so the fixtures stay readable and don't each re-implement the same parsing.

  @doc """
  Read request bytes until the end-of-headers marker (or a sane cap), so a request
  split across TCP segments still yields the full headers. Returns what it has on
  a recv error/timeout rather than blocking forever.
  """
  @spec recv_request(:gen_tcp.socket()) :: String.t()
  def recv_request(socket), do: recv_request(socket, "")

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

  @doc "The (case-insensitive) value of request header `name`, or `\"\"` if absent."
  @spec header_value(String.t(), String.t()) :: String.t()
  def header_value(request, name) do
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

  @doc "Build a complete `Connection: close` HTTP/1.1 response with the given status and body."
  @spec http_response(String.t(), String.t(), [String.t()]) :: String.t()
  def http_response(status, body, extra_headers \\ []) do
    headers =
      [
        "HTTP/1.1 #{status}",
        "Content-Type: text/html; charset=utf-8",
        "Content-Length: #{byte_size(body)}",
        "Connection: close"
        | extra_headers
      ]

    Enum.join(headers, "\r\n") <> "\r\n\r\n" <> body
  end
end
