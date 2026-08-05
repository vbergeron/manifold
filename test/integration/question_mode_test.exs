defmodule Manifold.Integration.QuestionModeTest do
  use Manifold.EngineCase, async: false

  # `Manifold.Turn.run/4` is the thing under test, driven the same way
  # `scripts/ws_smoke.exs` drives it: via `Conversation.run_turn/4`, collecting
  # the events sent to this process until `turn_done`. No model is loaded in
  # `:test` (config/test.exs), so `respond` degrades to its deterministic
  # fallback — which is exactly what lets these assertions pin the *evidence*
  # reaching `respond` without depending on any model output.

  setup do
    {_id, conv} = open_conversation!()
    {:ok, conv: conv}
  end

  defp run(conv, turn, text) do
    :ok = Conversation.run_turn(conv, turn, text, self())
    drain(turn, [])
  end

  defp drain(turn, acc) do
    receive do
      {:manifold_event, %{turn: ^turn, type: "turn_done"} = e} -> Enum.reverse([e | acc])
      {:manifold_event, %{turn: ^turn} = e} -> drain(turn, [e | acc])
    after
      10_000 -> raise "turn #{turn} never emitted turn_done; got #{inspect(Enum.map(acc, & &1.type))}"
    end
  end

  defp types(events), do: Enum.map(events, & &1.type)
  defp phases(events), do: events |> Enum.filter(&(&1.type == "turn_phase")) |> Enum.map(& &1.payload.phase)

  describe "a message opening with ?" do
    setup %{conv: conv} do
      Conversation.assert(conv, ["human(socrates)", "mortal(X) :- human(X)"])
      :ok
    end

    test "runs its text as a goal, skipping gate, extract, assert and check", %{conv: conv} do
      before = Conversation.kb_snapshot(conv)
      events = run(conv, "t_q1", "? mortal(socrates).")

      # The two phases question mode still runs, and none of the four it skips —
      # deliberately not pinned to the *full* event list, which also carries
      # respond's own `llama_unavailable`/token fallback shape.
      assert phases(events) == ["query", "respond"]

      assert List.first(types(events)) == "turn_started"
      assert List.last(types(events)) == "turn_done"

      second = Enum.at(events, 1)
      assert second.type == "message"
      assert second.payload.kind == "user"

      assert Enum.count(events, &(&1.type == "assistant_message")) == 1

      # Nothing was learned: question mode never reaches extract/assert.
      assert Conversation.kb_snapshot(conv) == before
    end

    test "the goal is the text with its ? (and trailing period) stripped", %{conv: conv} do
      events = run(conv, "t_q2", "? mortal(socrates).")
      query = Enum.find(events, &(&1.type == "message" and &1.payload.kind == "query"))

      assert query.payload.goal == "mortal(socrates)"
      assert query.payload.answer == true
    end

    test "accepts the ?- form, mirroring swipl's own prompt", %{conv: conv} do
      events = run(conv, "t_q3", "?- mortal(zeus).")
      query = Enum.find(events, &(&1.type == "message" and &1.payload.kind == "query"))

      assert query.payload.goal == "mortal(zeus)"
      assert query.payload.answer == false
    end

    test "the user message keeps the raw text, ? included", %{conv: conv} do
      events = run(conv, "t_q4", "? mortal(socrates).")
      user = Enum.find(events, &(&1.type == "message" and &1.payload.kind == "user"))

      assert user.payload.text == "? mortal(socrates)."
    end

    test "the answer is fed back as evidence for respond to react to", %{conv: conv} do
      events = run(conv, "t_q5", "? mortal(socrates).")
      reply = Enum.find(events, &(&1.type == "assistant_message"))

      # No model in :test, so `respond` falls back to a deterministic summary of
      # the evidence block — this is what proves the query's answer reached it.
      assert reply.payload.text =~ "mortal(socrates)"
    end

    test "an ordinary question mark does not trigger question mode", %{conv: conv} do
      events = run(conv, "t_q6", "Is Socrates mortal?")
      # `Clause.question?/1` only fires on a *leading* `?`; a trailing one still
      # goes through the gate, unlike question mode which never does.
      assert "gate" in phases(events)
    end
  end

  describe "an empty question" do
    test "surfaces bad_message instead of reaching Prolog", %{conv: conv} do
      events = run(conv, "t_q7", "?")

      assert Enum.any?(events, &(&1.type == "error" and &1.payload.code == "bad_message"))
      refute Enum.any?(events, &(&1.type == "message" and &1.payload.kind == "query"))
      assert Enum.any?(events, &(&1.type == "assistant_message"))
    end
  end
end
