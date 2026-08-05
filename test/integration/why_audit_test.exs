defmodule Manifold.Integration.WhyAuditTest do
  # Not async, for the same reason as `WhyMetaInterpreterTest`: `:prelude_path`
  # is process-global app env, shared with every other test.
  use Manifold.EngineCase, async: false

  # `WhyMetaInterpreterTest` pins the shape `why/2` hands back; this tier
  # checks the one thing that test doesn't: that `Manifold.Turn` recognizes
  # that shape and attaches it to the `query` message as a rendered audit
  # tree, instead of leaving it to flatten into `answer` like every other
  # query. Driven through question mode, the same way `QuestionModeTest`
  # drives the turn loop — the other route a goal reaches `Manifold.Turn`'s
  # audit logic from (the model generating `why(...)` itself) has no model to
  # generate it with under `config/test.exs`, but both routes build their
  # `query` message through the same private helper, so this is the one
  # exercisable end to end.

  setup do
    put_env!(:prelude_path, Application.app_dir(:manifold, "priv/prelude.pl"))
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
      10_000 -> raise "turn #{turn} never emitted turn_done"
    end
  end

  defp query_message(events), do: Enum.find(events, &(&1.type == "message" and &1.payload.kind == "query"))

  test "a why/2 question's query message carries its proof as an audit tree", %{conv: conv} do
    Conversation.assert(conv, ["human(socrates)", "mortal(X) :- human(X)"])

    events = run(conv, "t_audit1", "? why(mortal(socrates), Proof).")
    query = query_message(events)

    assert query.payload.goal == "why(mortal(socrates), Proof)"
    assert [tree] = query.payload.audit
    assert tree == "mortal(socrates)  [rule]\n└─ human(socrates)  [fact]"
  end

  test "an ordinary question — no proof term bound — carries no :audit field", %{conv: conv} do
    Conversation.assert(conv, ["human(socrates)", "mortal(X) :- human(X)"])

    events = run(conv, "t_audit2", "? mortal(socrates).")
    query = query_message(events)

    assert query.payload.answer == true
    refute Map.has_key?(query.payload, :audit)
  end
end
