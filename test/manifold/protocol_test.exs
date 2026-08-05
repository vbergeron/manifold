defmodule Manifold.ProtocolTest do
  use ExUnit.Case, async: true

  alias Manifold.Event
  alias Manifold.Prolog.Answer
  alias Manifold.Web.Socket

  describe "Answer.encode/1" do
    test "true and false pass through as booleans" do
      assert Answer.encode(true) === true
      assert Answer.encode(false) === false
    end

    test "bindings become the wire shape the UI expects" do
      solutions = [[%{"functor" => "=", "args" => ["X", "socrates"]}]]
      assert %{bindings: [%{"X" => "socrates"}]} = Answer.encode({:bindings, solutions})
    end
  end

  describe "Answer.witness/1" do
    test "takes the first solution, which is the one a contradiction names" do
      solutions = [
        [%{"functor" => "=", "args" => ["A", "willy"]}],
        [%{"functor" => "=", "args" => ["A", "shamu"]}]
      ]

      assert Answer.witness({:bindings, solutions}) == %{"A" => "willy"}
    end

    test "there is no witness for a bare true or a false" do
      assert Answer.witness(true) == nil
      assert Answer.witness(false) == nil
    end
  end

  describe "Event.new/3" do
    test "carries the protocol version and the correlating turn" do
      envelope = Event.new(:kb_delta, "t_7", %{added: []})

      assert envelope.v == Event.version()
      assert envelope.type == "kb_delta"
      assert envelope.turn == "t_7"
      assert envelope.payload == %{added: []}
    end

    test "a session-level frame has a nil turn" do
      assert Event.new(:session, nil, %{}).turn == nil
    end

    test "stamps a wall-clock timestamp, so envelopes are never compared whole" do
      before = System.system_time(:millisecond)
      ts = Event.new(:turn_done, "t_1").ts
      assert ts >= before and ts <= System.system_time(:millisecond)
    end
  end

  describe "Event.emit/4" do
    test "sends the envelope to the subscriber" do
      Event.emit(self(), :turn_started, "t_1", %{})
      assert_received {:manifold_event, %{type: "turn_started", turn: "t_1"}}
    end

    test "emitting to no subscriber is a no-op, not a crash" do
      # The turn loop runs with `nil` whenever nobody is listening — the smoke scripts and
      # IEx both drive it that way — so this must not be an error path.
      assert Event.emit(nil, :turn_started, "t_1", %{}) == :ok
      refute_received {:manifold_event, _}
    end

    test "error/4 is an emit with a typed code" do
      Event.error(self(), "t_2", "prolog_timeout", "too slow")
      assert_received {:manifold_event, %{type: "error", payload: payload}}
      assert payload == %{code: "prolog_timeout", message: "too slow"}
    end
  end

  # The WebSock callbacks take an explicit state map, so every framing and error path is
  # directly callable with no socket, no Bandit and no conversation.
  describe "Socket framing and rejection" do
    setup do
      {:ok, state} = Socket.init([])
      {:ok, state: state}
    end

    defp decode_pushed({:push, frames, state}) do
      {Enum.map(frames, fn {:text, json} -> Jason.decode!(json) end), state}
    end

    defp send_frame(state, map) do
      Socket.handle_in({Jason.encode!(map), [opcode: :text]}, state)
    end

    test "an unknown protocol version is rejected at the door", %{state: state} do
      {[frame], _} = decode_pushed(send_frame(state, %{v: 99, type: "open", payload: %{}}))
      assert frame["type"] == "error"
      assert frame["payload"]["code"] == "bad_message"
    end

    test "a frame with no type is rejected", %{state: state} do
      {[frame], _} = decode_pushed(send_frame(state, %{v: 1, payload: %{}}))
      assert frame["payload"]["code"] == "bad_message"
    end

    test "a frame that is not JSON is rejected", %{state: state} do
      {[frame], _} = decode_pushed(Socket.handle_in({"{not json", [opcode: :text]}, state))
      assert frame["payload"]["code"] == "bad_message"
    end

    test "an unknown type is rejected", %{state: state} do
      {[frame], _} = decode_pushed(send_frame(state, %{v: 1, type: "nonsense", payload: %{}}))
      assert frame["payload"]["code"] == "bad_message"
      assert frame["payload"]["message"] =~ "nonsense"
    end

    for type <- ~w(user_message cancel_turn kb_request) do
      test "#{type} before open is rejected", %{state: state} do
        {[frame], _} = decode_pushed(send_frame(state, %{v: 1, type: unquote(type), payload: %{}}))
        assert frame["payload"]["code"] == "bad_message"
        assert frame["payload"]["message"] =~ "before open"
      end
    end
  end

  describe "Socket seq" do
    test "is monotonic from 1, which is what lets a client detect gaps and duplicates" do
      {:ok, state} = Socket.init([])

      {frames_a, state} = decode_pushed(send_frame(state, %{v: 1, type: "bogus", payload: %{}}))
      {frames_b, state} = decode_pushed(send_frame(state, %{v: 1, type: "bogus", payload: %{}}))
      {frames_c, _} = decode_pushed(send_frame(state, %{v: 1, type: "bogus", payload: %{}}))

      assert Enum.map(frames_a ++ frames_b ++ frames_c, & &1["seq"]) == [1, 2, 3]
    end

    test "a turn event forwarded from elsewhere is stamped in the same sequence" do
      {:ok, state} = Socket.init([])
      {_, state} = decode_pushed(send_frame(state, %{v: 1, type: "bogus", payload: %{}}))

      envelope = Event.new(:turn_done, "t_1", %{})
      {frames, _} = decode_pushed(Socket.handle_info({:manifold_event, envelope}, state))

      assert [%{"type" => "turn_done", "seq" => 2}] = frames
    end
  end

  describe "Socket keepalive" do
    test "any inbound frame counts as life" do
      {:ok, state} = Socket.init([])
      {:ok, refreshed} = Socket.handle_control({"", [opcode: :pong]}, state)
      assert refreshed.last_seen >= state.last_seen
    end

    test "an idle connection past the deadline is closed rather than pinged forever" do
      {:ok, state} = Socket.init([])
      stale = %{state | last_seen: state.last_seen - 200_000}
      assert {:stop, :normal, _} = Socket.handle_info(:ping, stale)
    end

    test "a live connection is pinged" do
      {:ok, state} = Socket.init([])
      assert {:push, {:ping, ""}, _} = Socket.handle_info(:ping, state)
    end
  end
end
