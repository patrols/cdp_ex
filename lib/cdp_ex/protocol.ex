defmodule CDPEx.Protocol do
  @moduledoc """
  Pure CDP wire helpers: JSON-RPC encoding, frame decoding, and message
  classification. No process state, no I/O — every function here is referentially
  transparent and unit-testable without a running Chrome.

  > Module note: this module aliases `Mint.WebSocket` as `WebSocket`.

  The Chrome DevTools Protocol is JSON-RPC 2.0-ish over a WebSocket:

    * a **command** is `%{"id" => n, "method" => "Domain.method", "params" => %{}}`
    * a **reply** echoes the `"id"` and carries either `"result"` or `"error"`
    * an **event** has a `"method"` and `"params"` but no `"id"`

  `CDPEx.Connection` owns the socket and drives these helpers.
  """

  alias Mint.WebSocket

  @prevent_alerts_js "window.alert=function(){};window.confirm=function(){return true};window.prompt=function(){return null};"

  @typedoc "A decoded `Mint.WebSocket` frame."
  @type frame :: WebSocket.frame() | {:close, integer(), binary()}

  @typedoc "The result of classifying a single decoded frame."
  @type classification ::
          {:reply, id :: pos_integer(), {:ok, map()} | {:error, map()}}
          | {:event, method :: String.t(), params :: map()}
          | {:ping, binary()}
          | :ignore

  @doc """
  Encodes a CDP command to JSON iodata.

  Pass a `session_id` to target a flattened session; omit it (the default) for
  commands sent on a page or browser socket directly.

  ## Examples

      iex> CDPEx.Protocol.encode("Page.navigate", %{"url" => "https://x.test"}, 1)
      ...> |> IO.iodata_to_binary()
      ...> |> Jason.decode!()
      %{"id" => 1, "method" => "Page.navigate", "params" => %{"url" => "https://x.test"}}

      iex> CDPEx.Protocol.encode("Page.enable", %{}, 7, "SID")
      ...> |> IO.iodata_to_binary()
      ...> |> Jason.decode!()
      %{"id" => 7, "method" => "Page.enable", "params" => %{}, "sessionId" => "SID"}
  """
  @spec encode(String.t(), map(), pos_integer(), String.t() | nil) :: iodata()
  def encode(method, params, id, session_id \\ nil)
      when is_binary(method) and is_map(params) and is_integer(id) do
    %{"id" => id, "method" => method, "params" => params}
    |> put_session(session_id)
    |> Jason.encode_to_iodata!()
  end

  defp put_session(payload, nil), do: payload
  defp put_session(payload, session_id), do: Map.put(payload, "sessionId", session_id)

  @doc """
  Decodes `Mint.WebSocket` stream responses for `ref` into a flat list of frames.

  Non-matching responses (other refs, status/headers) are ignored. Returns the
  advanced websocket along with the frames so the caller can thread state.
  """
  @spec decode_frames(WebSocket.t(), [term()], reference()) ::
          {:ok, WebSocket.t(), [frame()]} | {:error, term()}
  def decode_frames(websocket, responses, ref) do
    Enum.reduce_while(responses, {:ok, websocket, []}, fn
      {:data, ^ref, data}, {:ok, ws, acc} ->
        case WebSocket.decode(ws, data) do
          {:ok, ws, frames} -> {:cont, {:ok, ws, acc ++ frames}}
          {:error, _ws, reason} -> {:halt, {:error, {:ws_decode, reason}}}
        end

      _other, acc ->
        {:cont, acc}
    end)
  end

  @doc """
  Classifies one decoded frame into a CDP-level action.

  Text frames are parsed as JSON and split into replies (by `"id"`) and events
  (by `"method"`). Ping frames surface so the connection can pong. Everything
  else (`pong`, `close`, unrecognised JSON) is `:ignore`.

  For an error reply, the raw CDP error object is returned; the connection wraps
  it with the originating method as `{:cdp_error, method, error}`.

  ## Examples

      iex> CDPEx.Protocol.classify({:text, ~s({"id":1,"result":{"frameId":"A"}})})
      {:reply, 1, {:ok, %{"frameId" => "A"}}}

      iex> CDPEx.Protocol.classify({:text, ~s({"id":2,"error":{"code":-32000,"message":"boom"}})})
      {:reply, 2, {:error, %{"code" => -32000, "message" => "boom"}}}

      iex> CDPEx.Protocol.classify({:text, ~s({"method":"Page.loadEventFired","params":{"t":1}})})
      {:event, "Page.loadEventFired", %{"t" => 1}}

      iex> CDPEx.Protocol.classify({:text, ~s({"method":"Inspector.detached"})})
      {:event, "Inspector.detached", %{}}

      iex> CDPEx.Protocol.classify({:ping, "hi"})
      {:ping, "hi"}

      iex> CDPEx.Protocol.classify({:pong, "hi"})
      :ignore
  """
  @spec classify(frame()) :: classification()
  def classify({:text, text}) do
    case Jason.decode(text) do
      {:ok, %{"id" => id, "result" => result}} -> {:reply, id, {:ok, result}}
      {:ok, %{"id" => id, "error" => error}} -> {:reply, id, {:error, error}}
      {:ok, %{"method" => method} = msg} -> {:event, method, Map.get(msg, "params", %{})}
      _other -> :ignore
    end
  end

  def classify({:ping, data}), do: {:ping, data}
  def classify(_other), do: :ignore

  @doc """
  Unwraps a `Runtime.evaluate` result.

  A thrown JS exception becomes `{:error, {:evaluate_exception, details}}`; a
  returned value (with `returnByValue: true`) becomes `{:ok, value}`; `undefined`
  becomes `{:ok, nil}`.

  ## Examples

      iex> CDPEx.Protocol.evaluate_result(%{"result" => %{"type" => "string", "value" => "<html>"}})
      {:ok, "<html>"}

      iex> CDPEx.Protocol.evaluate_result(%{"result" => %{"type" => "number", "value" => 42}})
      {:ok, 42}

      iex> CDPEx.Protocol.evaluate_result(%{"result" => %{"type" => "undefined"}})
      {:ok, nil}

      iex> {:error, {:evaluate_exception, _}} =
      ...>   CDPEx.Protocol.evaluate_result(%{"exceptionDetails" => %{"text" => "Uncaught"}})
  """
  @spec evaluate_result(map()) :: {:ok, term()} | {:error, term()}
  def evaluate_result(%{"exceptionDetails" => details}),
    do: {:error, {:evaluate_exception, details}}

  def evaluate_result(%{"result" => %{"value" => value}}), do: {:ok, value}
  def evaluate_result(%{"result" => %{"type" => "undefined"}}), do: {:ok, nil}
  def evaluate_result(other), do: {:error, {:unexpected_evaluate, other}}

  @doc """
  Splits a Chrome DevTools websocket URL into `{host, port, path}`.

  ## Examples

      iex> CDPEx.Protocol.parse_ws_url("ws://127.0.0.1:9222/devtools/browser/abc-123")
      {"127.0.0.1", 9222, "/devtools/browser/abc-123"}
  """
  @spec parse_ws_url(String.t()) :: {String.t(), pos_integer(), String.t()}
  def parse_ws_url("ws://" <> rest) do
    [host_port | path_parts] = String.split(rest, "/", parts: 2)
    [host, port] = String.split(host_port, ":")
    {host, String.to_integer(port), "/" <> (List.first(path_parts) || "")}
  end

  @doc """
  JavaScript that neutralises `alert`/`confirm`/`prompt` so modal dialogs can't
  block automation. Injected via `Page.addScriptToEvaluateOnNewDocument`.
  """
  @spec prevent_alerts_js() :: String.t()
  def prevent_alerts_js, do: @prevent_alerts_js
end
