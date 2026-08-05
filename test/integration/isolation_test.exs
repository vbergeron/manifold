defmodule Manifold.Integration.IsolationTest do
  # Not async: these share the conversation registry, the capacity counter, and the machine's
  # swipl processes.
  use Manifold.EngineCase, async: false

  # One test kills an engine on purpose, and the conversation is meant to die noisily.
  @moduletag :capture_log

  # The property the per-conversation-engine architecture exists for, and which was
  # completely untested while it was silently broken: MQI gives each *connection* its own
  # thread but not its own database, so with one shared server every conversation's
  # knowledge base merged into every other's.
  #
  # Three of these assertions cannot be satisfied by any per-connection trick — not even
  # `thread_local` predicates — because they use state that is global to the OS process.
  # Those are the ones that actually prove the architecture.

  setup do
    {_id_a, a} = open_conversation!()
    {_id_b, b} = open_conversation!()
    {:ok, a: a, b: b}
  end

  test "each conversation is a separate OS process", %{a: a, b: b} do
    # Counted through the registry rather than `pgrep -x swipl`, which is machine-wide and
    # would pass spuriously whenever another Manifold happens to be running.
    assert engine_count() >= 2
    assert Conversation.query(a, "true") == {:ok, true}
    assert Conversation.query(b, "true") == {:ok, true}
  end

  test "clauses asserted in one are invisible to the other", %{a: a, b: b} do
    Conversation.assert(a, ["secret_of_a(xyzzy)"])

    assert Conversation.query(a, "secret_of_a(xyzzy)") == {:ok, true}
    assert Conversation.query(b, "secret_of_a(X)") == {:ok, false}
    assert Conversation.kb_snapshot(b) == []
  end

  test "a process-global counter does not leak", %{a: a, b: b} do
    # `flag/3` is global to the swipl process. Ground terms only, so the answer is a plain
    # true/false rather than bindings.
    assert Conversation.query(a, "flag(shared, _, 42)") == {:ok, true}
    assert Conversation.query(a, "flag(shared, 42, 42)") == {:ok, true}

    assert Conversation.query(b, "flag(shared, 0, 0)") == {:ok, true},
           "B should still see the counter at its initial value"

    assert Conversation.query(b, "flag(shared, 42, 42)") == {:ok, false}
  end

  test "the operator table does not leak", %{a: a, b: b} do
    # `op/3` mutates a process-wide table. In B the operator is simply unknown, so the term
    # is a syntax error rather than a failed goal.
    assert Conversation.query(a, "op(700, xfx, (~~>))") == {:ok, true}
    refute Conversation.query(a, "X = (a ~~> b)") == {:ok, false}
    assert {:error, _} = Conversation.query(b, "X = (a ~~> b)")
  end

  test "even an assert that bypasses the normal path stays private", %{a: a, b: b} do
    # This is the case isolation-by-discipline could never cover: a raw `assertz` that never
    # went through the code which used to declare predicates `thread_local`. The OS boundary
    # contains it regardless of how it was asserted.
    assert Conversation.query(a, "assertz(undeclared_ghost(boo))") == {:ok, true}
    assert Conversation.query(b, "undeclared_ghost(X)") == {:ok, false}
  end

  test "killing one engine leaves the other untouched", %{a: a, b: b} do
    {id_c, c} = open_conversation!()
    Conversation.assert(c, ["only_in_c(1)"])
    Conversation.assert(b, ["only_in_b(1)"])

    :ok = Manifold.kill_engine(id_c)

    # C dies with its engine; B and A carry on. `:temporary` means nothing restarts C.
    eventually(fn -> not Process.alive?(c) end)
    assert Conversation.query(b, "only_in_b(1)") == {:ok, true}
    assert Conversation.query(a, "true") == {:ok, true}
  end
end
