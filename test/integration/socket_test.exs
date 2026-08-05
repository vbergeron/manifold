defmodule Manifold.Integration.SocketTest do
  use Manifold.EngineCase, async: false

  alias Manifold.Test.WsClient

  # Speaks the real wire against the endpoint this same VM is serving, because the protocol
  # is ours end to end: framing, `seq` and keepalive are all hand-rolled, so calling the
  # handler directly would test less than half of it. The pure error paths are covered
  # without a socket in test/manifold/protocol_test.exs; what needs a real connection is the
  # handshake, the ordering, and the sequence numbering across frames.

  setup do
    port = Application.get_env(:manifold, :web_port)
    sock = WsClient.connect("127.0.0.1", port, "/socket")
    on_exit(fn -> :gen_tcp.close(sock) end)
    {:ok, sock: sock}
  end

  test "opening hands over the full server-authoritative state, in order", %{sock: sock} do
    {id, conv} = open_conversation!()
    Conversation.assert(conv, ["human(socrates)"])
    Conversation.add_message(conv, "t1", :user, %{text: "hello"})

    WsClient.send_frame(sock, "open", nil, %{conversation_id: id})

    session = WsClient.recv(sock)
    kb = WsClient.recv(sock)
    transcript = WsClient.recv(sock)

    # A reconnecting client needs no replay buffer: it re-opens and takes both snapshots.
    assert session["type"] == "session"
    assert session["payload"]["conversation_id"] == id
    assert is_map(session["payload"]["sidecars"])
    assert kb["type"] == "kb_snapshot"
    assert transcript["type"] == "transcript_snapshot"

    # `seq` is assigned in send order, which is what lets a client spot gaps and drop
    # duplicates after a reconnect.
    assert Enum.map([session, kb, transcript], & &1["seq"]) == [1, 2, 3]

    assert length(kb["payload"]["clauses"]) == 1
    assert length(transcript["payload"]["messages"]) == 1
  end

  test "sidecars.prolog describes this conversation's own engine", %{sock: sock} do
    {id, _conv} = open_conversation!()
    WsClient.send_frame(sock, "open", nil, %{conversation_id: id})

    session = WsClient.recv(sock)

    # There is no shared Prolog server any more, so this is per-conversation — and it is
    # `true` whenever a client can see it, because a session frame is only sent once the
    # engine is ready.
    assert session["payload"]["sidecars"]["prolog"] == true
  end

  test "kb_request re-sends the snapshot, continuing the sequence", %{sock: sock} do
    {id, _conv} = open_conversation!()
    WsClient.send_frame(sock, "open", nil, %{conversation_id: id})
    for _ <- 1..3, do: WsClient.recv(sock)

    WsClient.send_frame(sock, "kb_request", nil, %{})
    again = WsClient.recv(sock)

    assert again["type"] == "kb_snapshot"
    assert again["seq"] == 4
  end

  test "a turn started over the wire can be cancelled", %{sock: sock} do
    {id, conv} = open_conversation!()
    WsClient.send_frame(sock, "open", nil, %{conversation_id: id})
    for _ <- 1..3, do: WsClient.recv(sock)

    WsClient.send_frame(sock, "user_message", "t_ws", %{text: "Zeus is a god."})
    started = WsClient.recv(sock)
    assert started["type"] == "turn_started"
    assert started["turn"] == "t_ws", "the client mints the turn id"

    WsClient.send_frame(sock, "cancel_turn", "t_ws", %{})

    # Cancelling closes the turn rather than leaving it dangling.
    {done, _earlier} = WsClient.recv_until(sock, ["turn_done"])
    assert done["type"] == "turn_done"
    assert Conversation.current_turn(conv) == nil
  end

  test "a second turn cannot start while one is in flight", %{sock: sock} do
    {id, _conv} = open_conversation!()
    WsClient.send_frame(sock, "open", nil, %{conversation_id: id})
    for _ <- 1..3, do: WsClient.recv(sock)

    WsClient.send_frame(sock, "user_message", "t_1", %{text: "Socrates is a human."})
    assert WsClient.recv(sock)["type"] == "turn_started"

    WsClient.send_frame(sock, "user_message", "t_2", %{text: "And Plato."})
    {frame, _} = WsClient.recv_until(sock, ["error"])
    assert frame["payload"]["code"] == "bad_message"
    assert frame["payload"]["message"] =~ "already running"
  end

  test "an empty user_message is refused", %{sock: sock} do
    {id, _conv} = open_conversation!()
    WsClient.send_frame(sock, "open", nil, %{conversation_id: id})
    for _ <- 1..3, do: WsClient.recv(sock)

    WsClient.send_frame(sock, "user_message", "t_x", %{text: ""})
    {frame, _} = WsClient.recv_until(sock, ["error"])
    assert frame["payload"]["code"] == "bad_message"
  end

  test "opening without an id mints a fresh conversation", %{sock: sock} do
    WsClient.send_frame(sock, "open", nil, %{conversation_id: nil})
    session = WsClient.recv(sock)

    id = session["payload"]["conversation_id"]
    assert is_binary(id) and id =~ ~r/^conv_/
    on_exit(fn -> Manifold.stop_conversation(id) end)
  end
end
