defmodule CDPEx.Telemetry do
  @moduledoc """
  The `:telemetry` events CDPEx emits.

  CDPEx is **silent by default**: it emits these events but attaches no handlers.
  Attach your own with `:telemetry.attach/4` (or a reporter like `Telemetry.Metrics`)
  to record them. Emitting with no handler attached is a cheap no-op.

  Handlers run **synchronously in the process that emits the event** — including the
  `CDPEx.Browser` / `CDPEx.Connection` GenServers, where error events fire immediately
  before that process stops. Keep handlers fast (offload slow work to a `Task` or a
  queue); a slow handler delays the emitting process and, for error events, Chrome
  teardown.

  ## Events

  ### `[:cdp_ex, :launch, :start | :stop | :exception]`

  A [span](`:telemetry.span/3`) around `CDPEx.launch/1` — Chrome spawn, WebSocket
  connect, and bootstrap. `:stop` carries the span `:duration` (in `:native` time
  units); its metadata is `%{}` on success or `%{error: reason}` when the launch
  failed. A failed launch still completes through `:stop` (the browser never started);
  only a raised exception emits `:exception`.

  ### `[:cdp_ex, :navigate, :start | :stop | :exception]`

  A span around `CDPEx.Page.navigate/3`.

    * `:start` metadata — `%{url: url}`
    * `:stop` metadata — `%{url, status, final_url}` plus `:error` when the navigation
      failed. `status` and `final_url` are `nil` unless the call used `response: true`
      (see `CDPEx.Page.navigate/3`) — `nil` means "not requested", not "unknown". A
      navigation **error tuple flows through `:stop`** (with `:error` in the metadata),
      not `:exception`.

  Both spans' metadata also carry `:telemetry_span_context` (injected by
  `:telemetry.span/3` to correlate `:start`/`:stop`/`:exception`).

  ### `[:cdp_ex, :page, :start]` and `[:cdp_ex, :page, :stop]`

  Emitted when a page is opened (`CDPEx.new_page/2`) and closed (`CDPEx.close_page/2`).

    * measurements — `%{system_time: System.system_time()}`
    * metadata — `%{target_id, transport}` where `transport` is `:dedicated` or `:session`

  `:stop` fires only on an explicit `close_page/2`. A page that dies any other way (a
  Chrome crash, the browser connection going down) emits `[:cdp_ex, :error]` **instead**
  of `:stop` — so a gauge built by pairing `:start`/`:stop` should also decrement on
  those errors, or use a counter.

  ### `[:cdp_ex, :error]`

  A genuine fault — a page's WebSocket closed unexpectedly, the browser connection went
  down, or Chrome exited.

    * measurements — `%{system_time: System.system_time()}`
    * metadata — `%{reason, context}`:
      * `:chrome_exited` — `reason` is the integer OS exit status
      * `:browser_connection_down` — `reason` is the connection's exit reason
      * `:ws_closed` — `reason` is the WebSocket close reason (e.g. `:closed`, or a
        `{code, binary}` peer close)

  > #### One fault can emit several events {: .info}
  >
  > A single Chrome death surfaces as one `:ws_closed` **per live connection** (each
  > dedicated page's, plus the browser's) and one `:browser_connection_down`, racing
  > with `:chrome_exited` (whichever the browser observes first). Treat them as one
  > incident per browser, not one fault each. A clean `CDPEx.stop/1` or `close_page/2`
  > emits **no** error event.

  ## Example

      :telemetry.attach(
        "log-cdp-navigate",
        [:cdp_ex, :navigate, :stop],
        fn _event, %{duration: dur}, %{url: url, status: status}, _config ->
          ms = System.convert_time_unit(dur, :native, :millisecond)
          IO.puts("navigated \#{url} -> \#{inspect(status)} in \#{ms}ms")
        end,
        nil
      )
  """
  @moduledoc since: "0.4.0"

  @typedoc "The CDPEx operations wrapped in a `:telemetry` span."
  @type span_name :: :launch | :navigate

  @doc false
  @spec span(span_name(), :telemetry.event_metadata(), (-> {result, map()})) :: result
        when result: var
  def span(name, start_metadata, fun) when name in [:launch, :navigate] do
    :telemetry.span([:cdp_ex, name], start_metadata, fun)
  end

  @doc false
  @spec page(:start | :stop, :telemetry.event_metadata()) :: :ok
  def page(stage, metadata) when stage in [:start, :stop] do
    :telemetry.execute([:cdp_ex, :page, stage], %{system_time: System.system_time()}, metadata)
  end

  @doc false
  @spec error(term(), :chrome_exited | :browser_connection_down | :ws_closed) :: :ok
  def error(reason, context) do
    :telemetry.execute(
      [:cdp_ex, :error],
      %{system_time: System.system_time()},
      %{reason: reason, context: context}
    )
  end
end
