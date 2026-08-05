defmodule Manifold.Integration.NoModelTest do
  use Manifold.EngineCase, async: false

  # The README claims "without a model the app still boots — the Prolog half is fully
  # functional". Nothing checked that, and it is exactly the sort of claim that rots.
  #
  # `config/test.exs` points `model_path` at a file that does not exist, so this tier runs
  # in the degraded state for free: `Llama.Server` parks in `:no_model` without spawning,
  # but still answers `endpoint/0`, so the client gets a real `{:error, _}` rather than
  # exiting `:noproc`. That is what makes the fallback reachable at all.

  @moduletag :capture_log

  setup do
    refute Manifold.Llama.Server.ready?(), "this tier is meant to run without a model"
    {_id, conv} = open_conversation!()
    {:ok, conv: conv}
  end

  test "the Prolog half is fully usable", %{conv: conv} do
    Conversation.assert(conv, ["human(socrates)", "mortal(X) :- human(X)"])
    assert Conversation.query(conv, "mortal(socrates)") == {:ok, true}
    assert Conversation.check_constraints(conv) == []
  end

  test "readiness reports the model missing and Prolog available" do
    ready = Manifold.ready?()
    refute ready.llama
    assert ready.prolog, "engines are spawnable regardless of the model"
  end

  describe "a turn with no model" do
    test "still completes, reports why, and closes the turn", %{conv: conv} do
      :ok = Conversation.run_turn(conv, "t_nomodel", "Socrates is a human.", self())

      events = drain_turn()
      types = Enum.map(events, & &1.type)

      # The loop must always reach `respond` and always close with `turn_done`, however badly
      # the model behaves — a failure there is reported as an event, not raised.
      assert "turn_started" in types
      assert "turn_done" == List.last(types)
      assert "assistant_message" in types

      assert Enum.any?(events, &(&1.type == "error" and &1.payload.code == "llama_unavailable")),
             "the missing model should be reported as a typed error"
    end

    test "the reply is a deterministic fallback, not silence", %{conv: conv} do
      Conversation.assert(conv, ["human(socrates)", "mortal(X) :- human(X)"])
      :ok = Conversation.run_turn(conv, "t_fb", "Is Socrates mortal?", self())

      events = drain_turn()
      reply = Enum.find(events, &(&1.type == "assistant_message")).payload.text

      assert is_binary(reply) and reply != ""
      assert reply =~ "no language model" or reply =~ "knowledge base",
             "expected the fallback wording, got: #{inspect(reply)}"
    end

    test "the transcript records the turn even though generation failed", %{conv: conv} do
      :ok = Conversation.run_turn(conv, "t_tx", "Socrates is a human.", self())
      drain_turn()

      kinds = Enum.map(Conversation.transcript_snapshot(conv), & &1.kind)
      assert "user" in kinds
      assert "assistant" in kinds
    end
  end

  # Collect one turn's events up to and including its terminating `turn_done`.
  defp drain_turn(acc \\ []) do
    receive do
      {:manifold_event, %{type: "turn_done"} = event} -> Enum.reverse([event | acc])
      {:manifold_event, event} -> drain_turn([event | acc])
    after
      60_000 ->
        raise "turn never emitted turn_done; saw #{inspect(Enum.map(acc, & &1.type))}"
    end
  end
end
