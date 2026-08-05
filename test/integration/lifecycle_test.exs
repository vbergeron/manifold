defmodule Manifold.Integration.LifecycleTest do
  use Manifold.EngineCase, async: false

  alias Manifold.Store

  @moduletag :capture_log

  # Admission control and idle eviction, neither of which any script tested. They matter
  # because one engine per conversation makes a conversation an OS-process-sized resource:
  # unbounded growth and no reaping would be a slow leak with nothing to notice it.

  describe "admission control" do
    setup do
      put_env!(:max_conversations, 2)
      :ok
    end

    test "a new conversation is refused once the cap is reached" do
      {_, _} = open_conversation!()
      {_, _} = open_conversation!()

      assert Manifold.open_conversation(nil) == {:error, :at_capacity}
    end

    test "refusing leaks no engine" do
      {_, _} = open_conversation!()
      {_, _} = open_conversation!()
      before = engine_count()

      assert {:error, :at_capacity} = Manifold.open_conversation(nil)
      assert engine_count() == before
    end

    test "a full server still admits a reconnect to a conversation it already holds" do
      # The ordering guarantee: capacity is checked *after* the registry lookup, so being at
      # capacity must never lock an already-admitted user out of their own state.
      {id, pid} = open_conversation!()
      {_, _} = open_conversation!()

      assert {:error, :at_capacity} = Manifold.open_conversation(nil)
      assert {:ok, ^id, ^pid} = Manifold.open_conversation(id)
    end

    test "freeing a slot admits again" do
      {id, _} = open_conversation!()
      {_, _} = open_conversation!()
      assert {:error, :at_capacity} = Manifold.open_conversation(nil)

      :ok = Manifold.stop_conversation(id)
      eventually(fn -> engine_count() < 2 end)

      assert {:ok, new_id, _} = Manifold.open_conversation(nil)
      on_exit(fn -> Manifold.stop_conversation(new_id) end)
    end

    test "readiness reports that no more engines can be spawned" do
      {_, _} = open_conversation!()
      {_, _} = open_conversation!()

      refute Manifold.engines_available?()
      refute Manifold.ready?().prolog
    end
  end

  describe "idle eviction" do
    setup do
      dir = Path.join(System.tmp_dir!(), "manifold-evict-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      put_env!(:store, {Store.Log, dir: dir})
      on_exit(fn -> File.rm_rf!(dir) end)
      # The check interval scales with the timeout, so a short timeout is honoured promptly
      # rather than waiting out a flat minute.
      put_env!(:conversation_idle_ms, 1_000)
      {:ok, dir: dir}
    end

    test "an idle, unattached conversation stops itself and takes its engine with it" do
      {id, conv} = open_conversation!()
      Conversation.assert(conv, ["human(socrates)", "mortal(X) :- human(X)"])
      before = engine_count()

      # `:normal`, deliberately — it is what lets a socket tell eviction apart from a crash.
      ref = Process.monitor(conv)
      assert_receive {:DOWN, ^ref, :process, _, :normal}, 10_000

      eventually(fn -> engine_count() < before end)

      # And it comes back on demand, from its log, with the engine rebuilt.
      {:ok, ^id, revived} = Manifold.open_conversation(id)
      on_exit(fn -> Manifold.stop_conversation(id) end)

      assert Enum.map(Conversation.kb_snapshot(revived), & &1.text) == [
               "human(socrates).",
               "mortal(X) :- human(X)."
             ]

      assert Conversation.query(revived, "mortal(socrates)") == {:ok, true}
    end

    test "an attached conversation is not evicted" do
      # Evicting a quiet-but-open browser tab would only cause an immediate reconnect and
      # rehydrate, which is pure churn.
      {_id, conv} = open_conversation!()
      %{prolog: true} = Conversation.attach(conv, self())

      ref = Process.monitor(conv)
      refute_receive {:DOWN, ^ref, :process, _, _}, 3_000
      assert Process.alive?(conv)
    end

    test "activity postpones eviction" do
      {_id, conv} = open_conversation!()
      ref = Process.monitor(conv)

      # Keep it busy for longer than the idle timeout.
      for _ <- 1..6 do
        Process.sleep(250)
        assert Conversation.query(conv, "true") == {:ok, true}
      end

      refute_received {:DOWN, ^ref, :process, _, _}
      assert Process.alive?(conv)
    end
  end

  describe "stopping" do
    test "a stopped conversation releases its engine" do
      {id, conv} = open_conversation!()
      before = engine_count()

      :ok = Manifold.stop_conversation(id)
      eventually(fn -> not Process.alive?(conv) end)
      eventually(fn -> engine_count() < before end)
    end

    test "stopping an unknown conversation says so rather than raising" do
      assert Manifold.stop_conversation("conv_does_not_exist") == {:error, :not_found}
    end

    test "conversations/0 reports the live count and the cap" do
      put_env!(:max_conversations, 7)
      assert %{live: live, capacity: 7} = Manifold.conversations()
      {_, _} = open_conversation!()
      assert Manifold.conversations().live == live + 1
    end
  end
end
