defmodule Manifold.Test.MQIFake do
  @moduledoc """
  A fake MQI server: a TCP listener that speaks the length-prefixed framing and replies
  with whatever you tell it to.

  Exists because the most valuable logic in `Manifold.Prolog.MQI` is unreachable otherwise.
  `parse/1` is pure and handles **three distinct wire encodings of failure** — a
  `{"functor": "false"}` object, the JSON *string* `"false"`, and the JSON boolean `false` —
  plus the `[[]]`-means-bare-`true` special case and a non-JSON fallback. All of it is
  private and only reachable through a socket. Rather than making it public for the tests'
  benefit, this drives the real code path end to end: framing, length parsing, and parsing.

  It also gives the only practical way to test the distinction the moduledoc insists on:
  `hang_up/1` closes the socket mid-exchange so a caller can prove it gets
  `{:error, {:transport, _}}` and not something indistinguishable from "Prolog says no".

  Usage:

      {:ok, fake} = MQIFake.start(replies: ["{\\"functor\\":\\"true\\",\\"args\\":[[[]]]}"])
      {:ok, conn} = MQI.connect(MQIFake.target(fake))
      assert MQI.run(conn, "anything") == {:ok, true}
  """
  use GenServer

  @password "test-password"

  @doc """
  Start a fake on an OS-assigned port.

  Options:

    * `:replies` — frame bodies to send, in order, one per `run/3`. A `:close` entry closes
      the socket instead of replying, simulating an engine that died mid-query.
    * `:password` — what the handshake expects (default `"#{@password}"`).
    * `:accept_auth` — `false` to reject the handshake.
  """
  @spec start(keyword()) :: {:ok, pid()}
  def start(opts \\ []), do: GenServer.start_link(__MODULE__, opts)

  @doc "Credentials for `Manifold.Prolog.MQI.connect/1`."
  @spec target(pid()) :: %{host: String.t(), port: pos_integer(), password: String.t()}
  def target(fake), do: GenServer.call(fake, :target)

  @doc "Close the accepted connection, as an engine dying would."
  @spec hang_up(pid()) :: :ok
  def hang_up(fake), do: GenServer.call(fake, :hang_up)

  @doc "Every message body the client sent, in order, with framing stripped."
  @spec received(pid()) :: [String.t()]
  def received(fake), do: GenServer.call(fake, :received)

  @impl true
  def init(opts) do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, packet: :raw, reuseaddr: true])
    {:ok, port} = :inet.port(listen)

    state = %{
      listen: listen,
      port: port,
      password: Keyword.get(opts, :password, @password),
      accept_auth: Keyword.get(opts, :accept_auth, true),
      replies: Keyword.get(opts, :replies, []),
      sock: nil,
      received: []
    }

    # Accept in a task so `init/1` returns and the client can connect. The task hands the
    # socket back rather than owning it, so `hang_up/1` can close it from this process.
    parent = self()
    spawn_link(fn -> accept_loop(parent, listen) end)
    {:ok, state}
  end

  @impl true
  def handle_call(:target, _from, s) do
    {:reply, %{host: "127.0.0.1", port: s.port, password: s.password}, s}
  end

  def handle_call(:received, _from, s), do: {:reply, Enum.reverse(s.received), s}

  def handle_call(:hang_up, _from, s) do
    if s.sock, do: :gen_tcp.close(s.sock)
    {:reply, :ok, %{s | sock: nil}}
  end

  def handle_call({:accepted, sock}, _from, s) do
    # Serve the whole conversation synchronously from here: handshake, then one reply per
    # request. A fake that is easy to reason about is worth more than a concurrent one.
    {:reply, :ok, serve(%{s | sock: sock})}
  end

  defp accept_loop(parent, listen) do
    case :gen_tcp.accept(listen, 5_000) do
      {:ok, sock} ->
        :ok = :gen_tcp.controlling_process(sock, parent)
        GenServer.call(parent, {:accepted, sock}, 30_000)

      {:error, _} ->
        :ok
    end
  end

  # The handshake: the client's first message is the password.
  defp serve(s) do
    case recv_message(s.sock) do
      {:ok, password} ->
        s = %{s | received: [password | s.received]}

        cond do
          password != s.password or not s.accept_auth ->
            send_message(s.sock, ~s|{"functor":"false"}|)
            s

          true ->
            send_message(s.sock, ~s|{"functor":"true","args":[[[]]]}|)
            answer_requests(s)
        end

      {:error, _} ->
        s
    end
  end

  defp answer_requests(%{replies: []} = s), do: s

  defp answer_requests(%{replies: [:close | rest]} = s) do
    # Read the request, then vanish without answering — an engine killed mid-query.
    _ = recv_message(s.sock)
    :gen_tcp.close(s.sock)
    %{s | sock: nil, replies: rest}
  end

  defp answer_requests(%{replies: [reply | rest]} = s) do
    case recv_message(s.sock) do
      {:ok, request} ->
        send_message(s.sock, reply)
        answer_requests(%{s | received: [request | s.received], replies: rest})

      {:error, _} ->
        %{s | replies: rest}
    end
  end

  # --- the wire format ---------------------------------------------------------
  #
  # The two directions are NOT symmetric, which is easy to get wrong:
  #
  #   client -> server   <len>.\n<prolog term>.\n     (a term, so it ends in a period)
  #   server -> client   <len>.\n<json>\n             (JSON, so it must NOT)
  #
  # Sending a period after the JSON makes `Jason.decode` fail and the real client reports
  # `{:non_json_reply, _}`. Verified against a live swipl: a `X is 6*7` answer arrives as
  # `74.\n{...}\n`, where 74 counts the JSON plus the newline and nothing else.

  defp send_message(sock, json) do
    message = json <> "\n"
    :gen_tcp.send(sock, "#{byte_size(message)}.\n" <> message)
  end

  defp recv_message(sock) do
    with {:ok, len} <- recv_length(sock, "") do
      case :gen_tcp.recv(sock, len, 5_000) do
        # Strip the newline, then the term's own period, leaving the bare payload.
        {:ok, body} -> {:ok, body |> String.trim_trailing() |> String.trim_trailing(".")}
        err -> err
      end
    end
  end

  defp recv_length(sock, acc) do
    case :gen_tcp.recv(sock, 1, 5_000) do
      {:ok, "."} ->
        case :gen_tcp.recv(sock, 1, 5_000) do
          {:ok, "\n"} -> {:ok, String.to_integer(acc)}
          other -> {:error, {:bad_frame, other}}
        end

      {:ok, digit} ->
        recv_length(sock, acc <> digit)

      err ->
        err
    end
  end
end
