defmodule CDPEx.Proxy do
  @moduledoc """
  Parses the `:proxy` launch option into a Chrome `--proxy-server` flag plus, when the
  proxy is authenticated, the credentials `CDPEx.Browser` arms on each page.

  Accepts either a URL string or a keyword list / map:

      "http://user:pass@host:8080"
      [server: "host:8080", scheme: "http", username: "user", password: "pass"]

  In the URL form, credentials with reserved characters must be percent-encoded
  (e.g. `p@ss` → `p%40ss`); they are decoded back on parse. The keyword form takes
  credentials verbatim, so prefer it when a password contains reserved characters.

  See the `:proxy` option on `CDPEx.launch/1`.
  """

  @typedoc """
  A parsed proxy: the `scheme://host:port` value for Chrome's `--proxy-server`
  (userinfo stripped), plus optional credentials (`nil` for an open proxy).
  """
  @type t :: %{server: String.t(), username: String.t() | nil, password: String.t() | nil}

  @doc """
  Parses a `:proxy` value into `{:ok, t}` or `{:error, {:invalid_proxy, reason}}`.
  """
  @spec parse(term()) :: {:ok, t()} | {:error, {:invalid_proxy, term()}}
  def parse(url) when is_binary(url), do: parse_url(url)
  def parse(opts) when is_list(opts), do: parse_opts(Map.new(opts))
  def parse(%{} = opts), do: parse_opts(opts)
  def parse(other), do: {:error, {:invalid_proxy, {:unsupported, other}}}

  @doc "The `--proxy-server=…` Chrome flag for a parsed proxy."
  @spec to_arg(t()) :: String.t()
  def to_arg(%{server: server}), do: "--proxy-server=#{server}"

  @doc """
  Credentials (`%{username, password}`) when the proxy needs auth, else `nil`.

  Both parts must be present and non-empty; a missing or empty half is treated as no
  auth (the proxy is used unauthenticated).
  """
  @spec credentials(t()) :: %{username: String.t(), password: String.t()} | nil
  def credentials(%{username: u, password: p}) when is_binary(u) and is_binary(p),
    do: %{username: u, password: p}

  def credentials(_), do: nil

  defp parse_url(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host, port: port} = uri
      when is_binary(scheme) and is_binary(host) and host != "" and is_integer(port) ->
        {user, pass} = split_userinfo(uri.userinfo)

        {:ok,
         %{server: "#{scheme}://#{host_for_server(host)}:#{port}", username: user, password: pass}}

      _ ->
        {:error, {:invalid_proxy, {:malformed_url, url}}}
    end
  end

  defp parse_opts(%{server: server} = opts) when is_binary(server) and server != "" do
    server = if String.contains?(server, "://"), do: server, else: "#{scheme(opts)}://#{server}"

    {:ok,
     %{
       server: server,
       username: blank_to_nil(opts[:username]),
       password: blank_to_nil(opts[:password])
     }}
  end

  defp parse_opts(opts), do: {:error, {:invalid_proxy, {:missing_server, opts}}}

  defp scheme(opts), do: Map.get(opts, :scheme, "http")

  # URI strips the brackets from an IPv6 literal (host: "::1"); re-wrap so the rebuilt
  # `host:port` stays unambiguous for Chrome (`[::1]:8080`, not `::1:8080`).
  defp host_for_server(host) do
    if String.contains?(host, ":"), do: "[#{host}]", else: host
  end

  # URI keeps userinfo encoded; decode the parts so a percent-encoded password round-trips.
  # An empty user/password is treated as absent (nil) so credentials/1 reads it as no auth.
  defp split_userinfo(nil), do: {nil, nil}

  defp split_userinfo(info) do
    case String.split(info, ":", parts: 2) do
      [user, pass] -> {blank_to_nil(URI.decode(user)), blank_to_nil(URI.decode(pass))}
      [user] -> {blank_to_nil(URI.decode(user)), nil}
    end
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value
end
