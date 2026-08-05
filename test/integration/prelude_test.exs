defmodule Manifold.Integration.PreludeTest do
  # Not async: shares the process-global `:prelude_path` app env with every other test.
  use Manifold.EngineCase, async: false

  @moduletag :capture_log

  # `:prelude_path` (`MANIFOLD_PRELUDE`) points at a Prolog file `consult/1`ed into every
  # conversation's own engine at boot — background rules and facts a deployment wants
  # available everywhere, without re-teaching them to the model or re-asserting them by
  # hand in each conversation. `config/test.exs` leaves it unset (`nil`), the same way
  # `model_path` is deliberately pointed at nothing, so this file is the only place the
  # capability is exercised.

  setup do
    dir = Path.join(System.tmp_dir!(), "manifold-prelude-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  defp prelude!(dir, source) do
    path = Path.join(dir, "prelude.pl")
    File.write!(path, source)
    path
  end

  test "a prelude rule is available before anything is asserted", %{dir: dir} do
    put_env!(:prelude_path, prelude!(dir, "greeting(hello).\n"))

    {_id, conv} = open_conversation!()

    assert Conversation.query(conv, "greeting(hello)") == {:ok, true}
  end

  test "prelude rules combine with clauses asserted during the conversation", %{dir: dir} do
    put_env!(:prelude_path, prelude!(dir, "mortal(X) :- human(X).\n"))

    {_id, conv} = open_conversation!()
    Conversation.assert(conv, ["human(socrates)"])

    assert Conversation.query(conv, "mortal(socrates)") == {:ok, true}
  end

  test "the prelude is not part of the KB snapshot", %{dir: dir} do
    put_env!(:prelude_path, prelude!(dir, "greeting(hello).\n"))

    {_id, conv} = open_conversation!()

    assert Conversation.kb_snapshot(conv) == []
  end

  test "every conversation gets its own copy — nothing leaks across engines", %{dir: dir} do
    put_env!(:prelude_path, prelude!(dir, "counter(0).\n"))

    {_id_a, a} = open_conversation!()
    {_id_b, b} = open_conversation!()

    Conversation.assert(a, ["seen(a)"])

    assert Conversation.query(a, "counter(0)") == {:ok, true}
    assert Conversation.query(b, "counter(0)") == {:ok, true}
    assert Conversation.query(b, "seen(a)") == {:ok, false}
  end

  test "a missing prelude file fails the conversation, not silently boots without it", %{dir: dir} do
    put_env!(:prelude_path, Path.join(dir, "does_not_exist.pl"))

    assert {:error, {:prolog_unavailable, {:prelude_failed, _path, _reason}}} =
             Manifold.open_conversation(nil)
  end
end
