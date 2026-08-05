defmodule Manifold.Integration.DurabilityTest do
  use Manifold.EngineCase, async: false

  alias Manifold.Store

  # Every test here kills an engine on purpose, and the conversation is supposed to complain
  # loudly and die when that happens. Capture it so a green run stays readable.
  @moduletag :capture_log

  # `config/test.exs` disables persistence by default so the suite never writes into the
  # repo. These tests need it, so they point the store at a temporary directory — which also
  # keeps each test's log out of every other's way.

  setup do
    dir = Path.join(System.tmp_dir!(), "manifold-durability-#{System.unique_integer([:positive])}")
    # The directory must exist before a conversation opens: `Store.setup/0` only runs at boot
    # with the boot-time config, and `Store.Log.open/2` on a missing directory degrades to
    # the null store with nothing but a log line to show for it.
    File.mkdir_p!(dir)
    put_env!(:store, {Store.Log, dir: dir})
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  test "a conversation survives losing its engine" do
    {id, conv} = open_conversation!()
    Conversation.assert(conv, ["human(socrates)", "mortal(X) :- human(X)"])
    before = Conversation.kb_snapshot(conv)

    :ok = Manifold.kill_engine(id)
    eventually(fn -> not Process.alive?(conv) end)

    {:ok, ^id, revived} = Manifold.open_conversation(id)
    assert revived != conv, "a new process should have taken the id"
    assert Conversation.kb_snapshot(revived) == before

    # The real proof is that the *engine* was rebuilt, not just the Elixir clause list.
    assert Conversation.query(revived, "mortal(socrates)") == {:ok, true}
    assert Conversation.query(revived, "mortal(zeus)") == {:ok, false}
  end

  test "replay asserts each clause exactly once" do
    # The bug this guards against is invisible to any assertion that only checks
    # provability: a doubled knowledge base still answers `true` to everything it answered
    # `true` to before. Only counting solutions reveals it — which is how the original
    # duplication went unnoticed until a query returned twelve solutions for six clauses.
    {id, conv} = open_conversation!()
    Conversation.assert(conv, ["p(1)", "p(2)"])

    :ok = Manifold.kill_engine(id)
    eventually(fn -> not Process.alive?(conv) end)
    {:ok, ^id, revived} = Manifold.open_conversation(id)

    assert {:ok, {:bindings, solutions}} = Conversation.query(revived, "p(X)")

    assert length(solutions) == 2,
           "expected one solution per clause, got #{length(solutions)} — the log was replayed into a dirty engine"
  end

  test "ids and counters continue past what was replayed" do
    {id, conv} = open_conversation!()
    Conversation.assert(conv, ["a(1)", "b(2)"])
    Conversation.add_message(conv, "t1", :user, %{text: "hello"})

    :ok = Manifold.kill_engine(id)
    eventually(fn -> not Process.alive?(conv) end)
    {:ok, ^id, revived} = Manifold.open_conversation(id)

    # Reusing an id would collide in the UI's id-keyed maps.
    assert [%{id: "c3"}] = Conversation.prepare_clauses(revived, "t2", ["c(3)"])
    assert %{id: "m2"} = Conversation.add_message(revived, "t2", :user, %{text: "again"})
  end

  test "a clause that was only prepared is not durable" do
    # Ids are burned by `prepare_clauses/3` whether or not the commit succeeds, but only
    # committed clauses are part of the knowledge base, so only those may be replayed.
    {id, conv} = open_conversation!()
    Conversation.assert(conv, ["kept(1)"])
    Conversation.prepare_clauses(conv, "t1", ["never_committed(1)"])

    :ok = Manifold.kill_engine(id)
    eventually(fn -> not Process.alive?(conv) end)
    {:ok, ^id, revived} = Manifold.open_conversation(id)

    assert Enum.map(Conversation.kb_snapshot(revived), & &1.text) == ["kept(1)."]
    assert Conversation.query(revived, "never_committed(X)") == {:ok, false}
  end

  test "a refused clause is not durable either" do
    # A fact carrying a variable is refused before it reaches Prolog, so replaying it would
    # be replaying a rejection.
    {id, conv} = open_conversation!()
    assert [{:error, reason}] = Conversation.assert(conv, ["pet(jane, _)"])
    assert reason =~ "may not contain variables"

    :ok = Manifold.kill_engine(id)
    eventually(fn -> not Process.alive?(conv) end)
    {:ok, ^id, revived} = Manifold.open_conversation(id)

    assert Conversation.kb_snapshot(revived) == []
  end

  test "a conversation with no id is deliberately not persisted" do
    # There is nothing a durable copy could be used for: it cannot be re-attached to.
    {:ok, conv} = Manifold.start_conversation()
    on_exit(fn -> if Process.alive?(conv), do: Manifold.stop_conversation(conv) end)

    Conversation.assert(conv, ["ephemeral(1)"])
    assert {:ok, ids} = Store.list()
    assert ids == [], "an id-less conversation must not create a log"
  end
end
