# Smoke test for the web half: drives the turn loop directly to check the event
# sequence it emits, then talks the real protocol over a real WebSocket to the
# Bandit endpoint this very app is serving.
#
# Run: mise exec -- mix run scripts/ws_smoke.exs
#
# Needs swipl (always) and a model at models/model.gguf (for the LLM phases; the
# script still passes without one — the turn loop degrades to `error
# {llama_unavailable}` plus a deterministic reply, which is itself worth seeing).
import Bitwise

# --- a WebSocket client small enough to trust -------------------------------
defmodule Ws do
  @moduledoc false

  def connect(host, port, path) do
    {:ok, sock} = :gen_tcp.connect(String.to_charlist(host), port, [:binary, active: false], 5_000)
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

  # Client frames must be masked (RFC 6455 §5.3).
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
  def recv(sock, timeout \\ 30_000) do
    {opcode, payload} = frame(sock, timeout)

    case opcode do
      0x1 -> Jason.decode!(payload)
      0x9 -> pong(sock, payload) && recv(sock, timeout)
      0xA -> recv(sock, timeout)
      0x8 -> {:close, payload}
      _ -> recv(sock, timeout)
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
    :gen_tcp.send(sock, <<0x8A, 0x80 ||| len>> <> mask <> :crypto.exor(payload, keystream(mask, len)))
    true
  end

  defp keystream(mask, len), do: binary_part(String.duplicate(mask, div(len, 4) + 1), 0, len)

  defp read_headers(sock, acc) do
    if String.contains?(acc, "\r\n\r\n") do
      {:ok, acc}
    else
      {:ok, chunk} = :gen_tcp.recv(sock, 0, 5_000)
      read_headers(sock, acc <> chunk)
    end
  end
end

defmodule Check do
  @moduledoc false
  def ok(label, true), do: IO.puts("  ok   #{label}")
  def ok(label, false), do: raise("FAILED: #{label}")
  def ok(label, cond_), do: ok(label, !!cond_)
end

wait = fn wait, label, fun, n ->
  cond do
    fun.() -> :ok
    n <= 0 -> raise "#{label} never became ready"
    true -> Process.sleep(500); wait.(wait, label, fun, n - 1)
  end
end

wait.(wait, "prolog", &Manifold.Prolog.Server.ready?/0, 60)

llama? =
  try do
    wait.(wait, "llama", &Manifold.Llama.Server.ready?/0, 240)
    true
  rescue
    _ -> false
  end

IO.puts("sidecars: #{inspect(Manifold.ready?())}#{if llama?, do: "", else: "  (LLM phases will degrade)"}")

# --- 1. the turn loop's event sequence, driven directly ---------------------
IO.puts("\n== turn loop events ==")
{:ok, conv_id, conv} = Manifold.open_conversation(nil)

# Collect the turn's events up to and including its terminating turn_done.
drain = fn drain, acc ->
  receive do
    {:manifold_event, %{type: "turn_done"} = e} -> Enum.reverse([e | acc])
    {:manifold_event, e} -> drain.(drain, [e | acc])
  after
    180_000 -> raise "turn never emitted turn_done; got #{inspect(Enum.map(acc, & &1.type))}"
  end
end

run = fn turn, text ->
  :ok = Manifold.Conversation.run_turn(conv, turn, text, self())
  events = drain.(drain, [])

  # Tokens are the noisy part; collapse consecutive runs for the printout.
  events
  |> Enum.map(& &1.type)
  |> Enum.chunk_by(& &1)
  |> Enum.map_join(" · ", fn
    [type] -> type
    [type | _] = repeated -> "#{type}×#{length(repeated)}"
  end)
  |> then(&IO.puts("  #{turn}: #{&1}"))

  events
end

turn1 = run.("t_1", "Socrates is a human. All humans are mortal. Is Socrates mortal?")

types1 = Enum.map(turn1, & &1.type)
Check.ok("starts with turn_started", hd(types1) == "turn_started")
Check.ok("second event is the user message", Enum.at(turn1, 1).type == "message")
Check.ok("user message kind=user", Enum.at(turn1, 1).payload.kind == "user")
Check.ok("ends with turn_done", List.last(types1) == "turn_done")
Check.ok("one gate_result", Enum.count(types1, &(&1 == "gate_result")) == 1)
Check.ok("exactly one assistant_message", Enum.count(types1, &(&1 == "assistant_message")) == 1)
Check.ok("phases are ordered", Enum.filter(turn1, &(&1.type == "turn_phase")) |> Enum.map(& &1.payload.phase) |> then(&(&1 == Enum.uniq(&1))))

phases1 = turn1 |> Enum.filter(&(&1.type == "turn_phase")) |> Enum.map(& &1.payload.phase)
IO.puts("  phases: #{Enum.join(phases1, " -> ")}")
Check.ok("gate then respond at minimum", "gate" in phases1 and "respond" in phases1)

if llama? do
  Check.ok("kb_delta added clauses", Enum.any?(turn1, &(&1.type == "kb_delta" and &1.payload.added != [])))
  Check.ok("clauses carry id/kind/turn", Enum.find(turn1, &(&1.type == "kb_delta")).payload.added |> Enum.all?(&match?(%{id: _, kind: _, turn: "t_1", text: _}, &1)))
  Check.ok("assistant tokens streamed", Enum.count(types1, &(&1 == "assistant_token")) > 0)
  # The message states facts *and* asks about them, so the loop must do both —
  # and the query must run after the assert, against the fresh KB.
  Check.ok("mixed message runs assert then query", Enum.filter(phases1, &(&1 in ["assert", "query"])) == ["assert", "query"])
end

for m <- Enum.filter(turn1, &(&1.type == "message" and &1.payload.kind == "query")) do
  IO.puts("  query: #{m.payload.goal} => #{inspect(m.payload.answer)}")
end

IO.puts("  reply: #{inspect(Enum.find(turn1, &(&1.type == "assistant_message")).payload.text)}")
IO.puts("  KB now: #{inspect(Enum.map(Manifold.Conversation.kb_snapshot(conv), & &1.text))}")

# --- 2. the contradiction path ---------------------------------------------
IO.puts("\n== contradiction path ==")
{:ok, _cid2, conv2} = Manifold.open_conversation(nil)
Manifold.Conversation.assert(conv2, ["whale(willy)", ":- whale(A), fish(A)"])
Check.ok("no violation yet", Manifold.Conversation.check_constraints(conv2) == [])

clauses = Manifold.Conversation.prepare_clauses(conv2, "t_x", ["fish(willy)"])
%{added: [_ | _]} = Manifold.Conversation.commit_clauses(conv2, clauses)
violations = Manifold.Conversation.check_constraints(conv2)
Check.ok("violation detected", match?([%{witness: %{"A" => "willy"}}], violations))
Check.ok("undefined predicates are not violations", Manifold.Conversation.query(conv2, "nosuch(X)") == {:ok, false})

# --- 3. the real socket -----------------------------------------------------
IO.puts("\n== websocket #{4000} ==")
port = Application.get_env(:manifold, :web_port, 4000)
sock = Ws.connect("127.0.0.1", port, "/socket")
Check.ok("upgraded to websocket on :#{port}", true)

Ws.send_text(sock, Jason.encode!(%{v: 1, type: "open", turn: nil, ts: 0, payload: %{conversation_id: conv_id}}))
session = Ws.recv(sock)
kb = Ws.recv(sock)
transcript = Ws.recv(sock)

Check.ok("session first", session["type"] == "session")
Check.ok("session carries the conversation id", session["payload"]["conversation_id"] == conv_id)
Check.ok("session carries sidecar readiness", is_map(session["payload"]["sidecars"]))
Check.ok("then kb_snapshot", kb["type"] == "kb_snapshot")
Check.ok("then transcript_snapshot", transcript["type"] == "transcript_snapshot")
Check.ok("seq is monotonic from 1", Enum.map([session, kb, transcript], & &1["seq"]) == [1, 2, 3])
Check.ok("reconnect sees the earlier turn", length(transcript["payload"]["messages"]) > 0)
Check.ok("reconnect sees the KB", length(kb["payload"]["clauses"]) == length(Manifold.Conversation.kb_snapshot(conv)))

Ws.send_text(sock, Jason.encode!(%{v: 1, type: "kb_request", turn: nil, ts: 0, payload: %{}}))
again = Ws.recv(sock)
Check.ok("kb_request re-sends kb_snapshot", again["type"] == "kb_snapshot" and again["seq"] == 4)

Ws.send_text(sock, Jason.encode!(%{v: 1, type: "nonsense", turn: nil, ts: 0, payload: %{}}))
bad = Ws.recv(sock)
Check.ok("unknown type -> error{bad_message}", bad["type"] == "error" and bad["payload"]["code"] == "bad_message")

Ws.send_text(sock, Jason.encode!(%{v: 99, type: "open", turn: nil, ts: 0, payload: %{}}))
version = Ws.recv(sock)
Check.ok("unknown v -> error{bad_message}", version["payload"]["code"] == "bad_message")

# A turn over the wire, cancelled halfway.
IO.puts("\n== turn over the wire, then cancel ==")
Ws.send_text(sock, Jason.encode!(%{v: 1, type: "user_message", turn: "t_ws", ts: 0, payload: %{text: "Zeus is a god."}}))
started = Ws.recv(sock)
Check.ok("turn_started with the client's turn id", started["type"] == "turn_started" and started["turn"] == "t_ws")

Ws.send_text(sock, Jason.encode!(%{v: 1, type: "cancel_turn", turn: "t_ws", ts: 0, payload: %{}}))

seen =
  Stream.repeatedly(fn -> Ws.recv(sock) end)
  |> Stream.take(200)
  |> Enum.take_while(&(&1["type"] != "turn_done"))

Check.ok("cancel closes the turn with turn_done (after #{length(seen)} events)", length(seen) < 200)
Check.ok("KB keeps what the cancelled turn already asserted", Manifold.Conversation.current_turn(conv) == nil)

IO.puts("\nall checks passed")
