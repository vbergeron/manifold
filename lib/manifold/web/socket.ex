defmodule Manifold.Web.Socket do
  @moduledoc """
  The `WebSock` handler: one socket ⇄ one conversation, speaking the envelope in
  `docs/PROTOCOL.md`.

  Its only jobs are **framing** (JSON in, JSON out), **sequencing** (`seq` is
  minted here because the counter is per connection), and **keepalive**. All
  state lives in the `Manifold.Conversation` it is attached to, which is
  *monitored, not linked*: the conversation must outlive the socket for
  `open {conversation_id}` reconnects to have anything to attach to.

  Turn events do not come back through this process's return values — the turn
  loop runs elsewhere and `send`s `{:manifold_event, envelope}` here as each
  phase completes, which is what makes the KB visibly mutate on the left while
  the reply streams on the right.
  """
  @behaviour WebSock

  require Logger

  alias Manifold.{Conversation, Event}

  @ping_interval 30_000
  # Three missed pings and the peer is gone. Any inbound frame counts as life.
  @idle_deadline 95_000

  @impl true
  def init(_opts) do
    schedule_ping()
    {:ok, %{seq: 0, conv: nil, conv_id: nil, monitor: nil, last_seen: now()}}
  end

  @impl true
  def handle_in({text, opcode: :text}, state) do
    state = %{state | last_seen: now()}

    case Jason.decode(text) do
      {:ok, %{"v" => v}} when v != 1 ->
        fail(state, nil, "bad_message", "unsupported protocol version #{inspect(v)}")

      {:ok, %{"type" => type} = frame} ->
        dispatch(type, frame, state)

      {:ok, _frame} ->
        fail(state, nil, "bad_message", "frame has no type")

      {:error, _reason} ->
        fail(state, nil, "bad_message", "frame is not JSON")
    end
  end

  def handle_in({_data, opcode: _other}, state), do: {:ok, %{state | last_seen: now()}}

  @impl true
  def handle_control({_data, opcode: _pong_or_ping}, state) do
    {:ok, %{state | last_seen: now()}}
  end

  @impl true
  def handle_info({:manifold_event, envelope}, state) do
    {frames, state} = stamp([envelope], state)
    {:push, frames, state}
  end

  def handle_info(:ping, state) do
    if now() - state.last_seen > @idle_deadline do
      Logger.info("[socket] closing idle connection (conversation=#{state.conv_id})")
      {:stop, :normal, state}
    else
      schedule_ping()
      {:push, {:ping, ""}, state}
    end
  end

  # The conversation died (MQI gone, or a supervisor restart). Say so; the client
  # can re-`open` to get a fresh one.
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{monitor: ref} = state) do
    state = %{state | conv: nil, monitor: nil}
    push(state, [{:error, nil, %{code: "internal", message: "conversation ended: #{inspect(reason)}"}}])
  end

  def handle_info(_msg, state), do: {:ok, state}

  @impl true
  def terminate(reason, state) do
    Logger.debug("[socket] terminate #{inspect(reason)} (conversation=#{state.conv_id})")
    :ok
  end

  # --- commands --------------------------------------------------------------

  # Attach to a conversation (creating one if the client has no id yet) and hand
  # over the full server-authoritative state: session, then both panels.
  defp dispatch("open", frame, state) do
    case Manifold.open_conversation(payload(frame)["conversation_id"]) do
      {:ok, id, pid} ->
        if state.monitor, do: Process.demonitor(state.monitor, [:flush])
        state = %{state | conv: pid, conv_id: id, monitor: Process.monitor(pid)}

        push(state, [
          {:session, nil, %{conversation_id: id, sidecars: Manifold.ready?()}},
          {:kb_snapshot, nil, %{clauses: Conversation.kb_snapshot(pid)}},
          {:transcript_snapshot, nil, %{messages: Conversation.transcript_snapshot(pid)}}
        ])

      {:error, reason} ->
        fail(state, nil, "prolog_unavailable", "cannot open a knowledge base: #{inspect(reason)}")
    end
  end

  defp dispatch("user_message", frame, %{conv: conv} = state) when is_pid(conv) do
    turn = frame["turn"] || mint_turn()

    case payload(frame)["text"] do
      text when is_binary(text) and text != "" ->
        case Conversation.run_turn(conv, turn, text, self()) do
          :ok -> {:ok, state}
          {:error, :turn_in_flight} -> fail(state, turn, "bad_message", "a turn is already running")
        end

      _ ->
        fail(state, turn, "bad_message", "user_message needs a non-empty text")
    end
  end

  defp dispatch("cancel_turn", _frame, %{conv: conv} = state) when is_pid(conv) do
    :ok = Conversation.cancel_turn(conv)
    {:ok, state}
  end

  defp dispatch("kb_request", _frame, %{conv: conv} = state) when is_pid(conv) do
    push(state, [{:kb_snapshot, nil, %{clauses: Conversation.kb_snapshot(conv)}}])
  end

  defp dispatch(type, _frame, %{conv: nil} = state) when type in ~w(user_message cancel_turn kb_request) do
    fail(state, nil, "bad_message", "#{type} before open")
  end

  defp dispatch(type, _frame, state) do
    fail(state, nil, "bad_message", "unknown type #{inspect(type)}")
  end

  # --- framing ---------------------------------------------------------------

  defp push(state, events) do
    {frames, state} = stamp(Enum.map(events, fn {t, turn, p} -> Event.new(t, turn, p) end), state)
    {:push, frames, state}
  end

  defp fail(state, turn, code, message) do
    Logger.debug("[socket] #{code}: #{message}")
    push(state, [{:error, turn, %{code: code, message: message}}])
  end

  # `seq` is assigned at the moment of sending, in send order — that is what lets
  # the client detect gaps and drop duplicates after a reconnect.
  defp stamp(envelopes, state) do
    Enum.map_reduce(envelopes, state, fn envelope, acc ->
      seq = acc.seq + 1
      {{:text, Jason.encode!(Map.put(envelope, :seq, seq))}, %{acc | seq: seq}}
    end)
  end

  defp payload(frame), do: Map.get(frame, "payload") || %{}

  defp mint_turn, do: "t_" <> Base.url_encode64(:crypto.strong_rand_bytes(6), padding: false)

  defp schedule_ping, do: Process.send_after(self(), :ping, @ping_interval)

  defp now, do: System.monotonic_time(:millisecond)
end
