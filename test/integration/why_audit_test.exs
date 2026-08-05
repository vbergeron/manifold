defmodule Manifold.Integration.WhyAuditTest do
  # Not async, for the same reason as `WhyMetaInterpreterTest`: `:prelude_path`
  # is process-global app env, shared with every other test.
  use Manifold.EngineCase, async: false

  import ExUnit.CaptureLog

  # `WhyMetaInterpreterTest` pins the shape `why/2` hands back; this tier
  # checks the one thing that test doesn't: that `Manifold.Turn` recognizes
  # that shape and logs it as an audit tree instead of leaving it to flatten
  # into an ordinary Prolog term alongside every other query answer. Driven
  # through question mode, the same way `QuestionModeTest` drives the turn
  # loop — the other route a goal reaches `Manifold.Turn.audit/3` from (the
  # model generating `why(...)` itself) has no model to generate it with under
  # `config/test.exs`, but both routes call the identical private helper, so
  # this is the one exercisable end to end.

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

  test "a why/2 question logs its proof as an audit tree", %{conv: conv} do
    Conversation.assert(conv, ["human(socrates)", "mortal(X) :- human(X)"])

    log =
      capture_log(fn ->
        run(conv, "t_audit1", "? why(mortal(socrates), Proof).")
      end)

    assert log =~ "audit — why(mortal(socrates), Proof)"
    assert log =~ "mortal(socrates)  [rule]"
    assert log =~ "└─ human(socrates)  [fact]"
  end

  test "an ordinary question — no proof term bound — logs no audit tree", %{conv: conv} do
    Conversation.assert(conv, ["human(socrates)", "mortal(X) :- human(X)"])

    log =
      capture_log(fn ->
        run(conv, "t_audit2", "? mortal(socrates).")
      end)

    refute log =~ "audit"
  end
end
