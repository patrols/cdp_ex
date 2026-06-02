defmodule CDPEx.FakeCDP do
  @moduledoc false
  # A minimal, dependency-free WebSocket server for testing `CDPEx.Connection`
  # without a real Chrome. Hand-rolls just enough of RFC 6455 to accept an
  # upgrade, receive (masked) client frames, and send (unmasked) server frames.
  #
  # The controlling process drives the conversation:
  #
  #     {:ok, server} = FakeCDP.start()
  #     {:ok, conn} = CDPEx.Connection.start_link(server.url)
  #     assert_receive {:fake_cdp_connected, fake}
  #     # ... Connection.call sends a command ...
  #     assert_receive {:fake_cdp_recv, ^fake, %{"id" => id}}
  #     FakeCDP.send_text(fake, ~s({"id":#{id},"result":{}}))
  #
  # Messages delivered to the controller:
  #   {:fake_cdp_connected, conn_pid}
  #   {:fake_cdp_recv, conn_pid, decoded_json_map}
  #
  # Per-connection controls: send_text/2, send_ping/2, close/1 (close frame),
  # hard_close/1 (abrupt TCP close, no close frame — simulates a crash).
  #
  # NB: side-effecting :gen_tcp/:inet calls are `_ =`-discarded so this file stays
  # clean under the strict Dialyzer flags (incl. :unmatched_returns) — `mix ci`
  # runs in MIX_ENV=test, where test/support is compiled and analyzed.

  import Bitwise

  @ws_magic "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

  @spec start(pid()) :: {:ok, %{port: non_neg_integer(), url: String.t(), listen: port()}}
  def start(controller \\ self()) do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)
    spawn_link(fn -> accept_loop(listen, controller) end)
    {:ok, %{port: port, url: "ws://127.0.0.1:#{port}/devtools/browser/fake", listen: listen}}
  end

  # Like start/1, but the server accepts the connection and reads the upgrade
  # request, then never sends the 101 — leaving CDPEx.Connection blocked in
  # recv_upgrade. Notifies the controller {:fake_cdp_stalled, conn_pid} once the
  # request is in, and {:fake_cdp_client_gone, conn_pid} when the client socket
  # closes (how a Connection that died mid-handshake surfaces).
  @spec start_stalling(pid()) :: {:ok, %{port: non_neg_integer(), url: String.t(), listen: port()}}
  def start_stalling(controller \\ self()) do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)
    spawn_link(fn -> accept_loop_stalling(listen, controller) end)
    {:ok, %{port: port, url: "ws://127.0.0.1:#{port}/devtools/browser/fake", listen: listen}}
  end

  @spec send_text(pid(), iodata()) :: :ok
  def send_text(conn, text) do
    send(conn, {:send_frame, 0x1, IO.iodata_to_binary(text)})
    :ok
  end

  @spec send_ping(pid(), binary()) :: :ok
  def send_ping(conn, data \\ "") do
    send(conn, {:send_frame, 0x9, data})
    :ok
  end

  @spec close(pid()) :: :ok
  def close(conn) do
    send(conn, :graceful_close)
    :ok
  end

  @spec hard_close(pid()) :: :ok
  def hard_close(conn) do
    send(conn, :hard_close)
    :ok
  end

  # ── server internals ────────────────────────────────────────────────────────

  defp accept_loop(listen, controller) do
    case :gen_tcp.accept(listen) do
      {:ok, socket} ->
        pid = spawn_link(fn -> serve(socket, controller) end)
        _ = :gen_tcp.controlling_process(socket, pid)
        send(pid, :go)
        accept_loop(listen, controller)

      {:error, :closed} ->
        :ok
    end
  end

  defp serve(socket, controller) do
    receive do
      :go -> :ok
    end

    :ok = handshake(socket)
    send(controller, {:fake_cdp_connected, self()})
    _ = :inet.setopts(socket, active: :once)
    loop(socket, controller, <<>>)
  end

  defp accept_loop_stalling(listen, controller) do
    case :gen_tcp.accept(listen) do
      {:ok, socket} ->
        pid = spawn_link(fn -> serve_stalling(socket, controller) end)
        _ = :gen_tcp.controlling_process(socket, pid)
        send(pid, :go)
        accept_loop_stalling(listen, controller)

      {:error, :closed} ->
        :ok
    end
  end

  defp serve_stalling(socket, controller) do
    receive do
      :go -> :ok
    end

    {:ok, _request} = recv_request(socket, "")
    send(controller, {:fake_cdp_stalled, self()})

    # Never send the 101. Watch for the client's TCP socket closing — which is how
    # a CDPEx.Connection that died mid-handshake (its owner exited) surfaces.
    _ = :inet.setopts(socket, active: :once)

    receive do
      {:tcp_closed, ^socket} -> send(controller, {:fake_cdp_client_gone, self()})
      :hard_close -> :gen_tcp.close(socket)
    after
      30_000 -> :gen_tcp.close(socket)
    end
  end

  defp loop(socket, controller, buffer) do
    receive do
      {:tcp, ^socket, data} ->
        {frames, rest} = parse_frames(buffer <> data, [])
        Enum.each(frames, &handle_frame(&1, socket, controller))
        _ = :inet.setopts(socket, active: :once)
        loop(socket, controller, rest)

      {:tcp_closed, ^socket} ->
        :ok

      {:send_frame, opcode, payload} ->
        _ = :gen_tcp.send(socket, encode_frame(opcode, payload))
        loop(socket, controller, buffer)

      :graceful_close ->
        _ = :gen_tcp.send(socket, encode_frame(0x8, <<1000::16>>))
        :gen_tcp.close(socket)

      :hard_close ->
        :gen_tcp.close(socket)
    end
  end

  defp handle_frame({0x1, payload}, _socket, controller) do
    send(controller, {:fake_cdp_recv, self(), Jason.decode!(payload)})
    :ok
  end

  defp handle_frame({0x9, payload}, socket, _controller) do
    # Respond to client ping with a pong (not exercised by the client, but correct).
    _ = :gen_tcp.send(socket, encode_frame(0xA, payload))
    :ok
  end

  defp handle_frame({0x8, _payload}, socket, _controller) do
    :gen_tcp.close(socket)
  end

  defp handle_frame(_other, _socket, _controller), do: :ok

  # ── handshake ───────────────────────────────────────────────────────────────

  defp handshake(socket) do
    {:ok, request} = recv_request(socket, "")
    key = extract_ws_key(request)

    accept =
      :sha
      |> :crypto.hash(key <> @ws_magic)
      |> Base.encode64()

    response =
      "HTTP/1.1 101 Switching Protocols\r\n" <>
        "Upgrade: websocket\r\nConnection: Upgrade\r\n" <>
        "Sec-WebSocket-Accept: #{accept}\r\n\r\n"

    _ = :gen_tcp.send(socket, response)
    :ok
  end

  defp recv_request(socket, acc) do
    if String.contains?(acc, "\r\n\r\n") do
      {:ok, acc}
    else
      {:ok, data} = :gen_tcp.recv(socket, 0)
      recv_request(socket, acc <> data)
    end
  end

  defp extract_ws_key(request) do
    [_, key] = Regex.run(~r/sec-websocket-key:\s*(\S+)/i, request)
    key
  end

  # ── frame parsing (client → server, masked) ─────────────────────────────────

  defp parse_frames(buffer, acc) do
    case parse_one(buffer) do
      {:ok, frame, rest} -> parse_frames(rest, [frame | acc])
      :incomplete -> {Enum.reverse(acc), buffer}
    end
  end

  defp parse_one(<<_fin_op::1, _rsv::3, opcode::4, mask_flag::1, len0::7, rest::binary>>) do
    parse_payload(opcode, mask_flag == 1, len0, rest)
  end

  defp parse_one(_), do: :incomplete

  defp parse_payload(opcode, masked?, 126, <<len::16, rest::binary>>),
    do: take_payload(opcode, masked?, len, rest)

  defp parse_payload(opcode, masked?, 127, <<len::64, rest::binary>>),
    do: take_payload(opcode, masked?, len, rest)

  defp parse_payload(_opcode, _masked?, len0, _rest) when len0 in [126, 127], do: :incomplete

  defp parse_payload(opcode, masked?, len0, rest), do: take_payload(opcode, masked?, len0, rest)

  defp take_payload(opcode, true, len, data) do
    case data do
      <<mask::binary-size(4), payload::binary-size(len), rest::binary>> ->
        {:ok, {opcode, unmask(payload, mask)}, rest}

      _ ->
        :incomplete
    end
  end

  defp take_payload(opcode, false, len, data) do
    case data do
      <<payload::binary-size(len), rest::binary>> -> {:ok, {opcode, payload}, rest}
      _ -> :incomplete
    end
  end

  defp unmask(payload, mask) do
    # elem/2 on a 4-tuple is O(1); Enum.at/2 on a list is O(n), making unmask
    # O(payload x 4) — negligible for tiny unit frames, slow for large ones.
    mask = mask |> :binary.bin_to_list() |> List.to_tuple()

    payload
    |> :binary.bin_to_list()
    |> Enum.with_index()
    |> Enum.map(fn {byte, i} -> bxor(byte, elem(mask, rem(i, 4))) end)
    |> :erlang.list_to_binary()
  end

  # ── frame encoding (server → client, unmasked) ──────────────────────────────

  defp encode_frame(opcode, payload) do
    len = byte_size(payload)
    first = 0x80 ||| opcode

    header =
      cond do
        len < 126 -> <<first, len>>
        len < 65_536 -> <<first, 126, len::16>>
        true -> <<first, 127, len::64>>
      end

    header <> payload
  end
end
