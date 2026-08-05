defmodule Manifold.Test.WsClient do
  @moduledoc """
  A WebSocket client small enough to trust, for testing `Manifold.Web.Socket`.

  Lifted verbatim in behaviour from `scripts/ws_smoke.exs`, where it was the largest
  reusable thing in the scripts and could not be shared. It exists because the protocol
  (`docs/PROTOCOL.md`) is ours: framing, `seq`, and keepalive are all hand-rolled, so a
  test needs to speak the real wire rather than call into the handler.

  Known limits, deliberate: it does not verify `Sec-WebSocket-Accept`, and it does not
  reassemble continuation frames. Every frame Manifold sends is a single unfragmented JSON
  text frame, so neither has come up — but a fragmented reply would be mis-decoded rather
  than failing loudly, which is worth knowing before trusting a confusing failure here.
  """
  import Bitwise

  @connect_timeout 5_000
  @recv_timeout 30_000

  @doc "Connect and upgrade, or raise with the server's refusal."
  @spec connect(String.t(), pos_integer(), String.t()) :: :gen_tcp.socket()
  def connect(host, port, path) do
    {:ok, sock} =
      :gen_tcp.connect(String.to_charlist(host), port, [:binary, active: false], @connect_timeout)

    key = Base.encode64(:crypto.strong_rand_bytes(16))

    :ok =
      :gen_tcp.send(sock, """
      GET #{path} HTTP/1.1\r
      Host: #{host}:#{port}\r
      Upgrade: websocket\r
      Connection: Upgrade\r
      Sec-WebSocket-Key: #{key}\r
      Sec-WebSocket-Version: 13\r
      \r
      """)

    {:ok, headers} = read_headers(sock, "")
    unless String.starts_with?(headers, "HTTP/1.1 101"), do: raise("upgrade refused:\n#{headers}")
    sock
  end

  @doc "Send a protocol frame, building the envelope around `payload`."
  @spec send_frame(:gen_tcp.socket(), String.t(), String.t() | nil, map()) :: :ok
  def send_frame(sock, type, turn, payload) do
    send_text(sock, Jason.encode!(%{v: 1, type: type, turn: turn, ts: 0, payload: payload}))
  end

  @doc "Send a raw text frame. Client frames must be masked (RFC 6455 §5.3)."
  @spec send_text(:gen_tcp.socket(), binary()) :: :ok
  def send_text(sock, payload) do
    mask = :crypto.strong_rand_bytes(4)
    len = byte_size(payload)

    header =
      cond do
        len < 126 -> <<0x81, 0x80 ||| len>>
        len < 65_536 -> <<0x81, 0x80 ||| 126, len::16>>
        true -> <<0x81, 0x80 ||| 127, len::64>>
      end

    :gen_tcp.send(sock, header <> mask <> :crypto.exor(payload, keystream(mask, len)))
  end

  @doc "Next data frame as a decoded envelope; pings/pongs are answered and skipped."
  @spec recv(:gen_tcp.socket(), timeout()) :: map() | {:close, binary()}
  def recv(sock, timeout \\ @recv_timeout) do
    {opcode, payload} = frame(sock, timeout)

    case opcode do
      0x1 -> Jason.decode!(payload)
      0x9 -> pong(sock, payload) && recv(sock, timeout)
      0xA -> recv(sock, timeout)
      0x8 -> {:close, payload}
      _ -> recv(sock, timeout)
    end
  end

  @doc "Collect frames until one of `types` arrives, returning `{matched, earlier}`."
  @spec recv_until(:gen_tcp.socket(), [String.t()], pos_integer()) :: {map(), [map()]}
  def recv_until(sock, types, max \\ 200), do: recv_until(sock, types, max, [])

  defp recv_until(_sock, types, 0, acc) do
    raise "never received any of #{inspect(types)}; saw #{inspect(Enum.map(acc, & &1["type"]))}"
  end

  defp recv_until(sock, types, max, acc) do
    frame = recv(sock)

    # `type in types` cannot be a guard here — `types` is a runtime list — so match in the
    # body instead.
    if is_map(frame) and frame["type"] in types do
      {frame, Enum.reverse(acc)}
    else
      recv_until(sock, types, max - 1, [frame | acc])
    end
  end

  defp frame(sock, timeout) do
    {:ok, <<first, len0>>} = :gen_tcp.recv(sock, 2, timeout)

    len =
      case len0 &&& 0x7F do
        126 -> with {:ok, <<l::16>>} <- :gen_tcp.recv(sock, 2, timeout), do: l
        127 -> with {:ok, <<l::64>>} <- :gen_tcp.recv(sock, 8, timeout), do: l
        l -> l
      end

    payload = if len == 0, do: "", else: with({:ok, p} <- :gen_tcp.recv(sock, len, timeout), do: p)
    {first &&& 0x0F, payload}
  end

  defp pong(sock, payload) do
    mask = :crypto.strong_rand_bytes(4)
    len = byte_size(payload)

    :gen_tcp.send(
      sock,
      <<0x8A, 0x80 ||| len>> <> mask <> :crypto.exor(payload, keystream(mask, len))
    )

    true
  end

  defp keystream(mask, len), do: binary_part(String.duplicate(mask, div(len, 4) + 1), 0, len)

  defp read_headers(sock, acc) do
    if String.contains?(acc, "\r\n\r\n") do
      {:ok, acc}
    else
      {:ok, chunk} = :gen_tcp.recv(sock, 0, @connect_timeout)
      read_headers(sock, acc <> chunk)
    end
  end
end
