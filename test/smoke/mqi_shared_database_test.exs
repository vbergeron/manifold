defmodule Manifold.Smoke.MQISharedDatabaseTest do
  use ExUnit.Case, async: false

  @moduletag :smoke
  @moduletag timeout: 60_000

  alias Manifold.Prolog.{Engine, MQI}

  @moduledoc """
  ASSUMPTION: two MQI connections into one `swipl` process share a global clause store, and
  clauses outlive the connection that asserted them.

  This is the premise the entire architecture rests on. If it ever stops holding — a future
  SWI-Prolog giving each connection its own database, say — then one engine per conversation
  becomes unnecessary and the cost could be reclaimed. Measured on SWI-Prolog 9.2.8.

  Run it when: upgrading SWI-Prolog, or wondering whether per-conversation engines are still
  worth ~5 MB and ~90 ms each.
  """

  setup do
    {:ok, engine} = Engine.start()
    {:ok, engine} = Engine.await_ready(engine)
    on_exit(fn -> Engine.stop(engine) end)
    {:ok, engine: engine}
  end

  test "a clause asserted on one connection is visible on another", %{engine: engine} do
    {:ok, a} = Engine.connect(engine)
    {:ok, b} = Engine.connect(engine)

    {:ok, _} = MQI.run(a, "assertz(secret_of_a(xyzzy))")

    assert {:ok, {:bindings, _}} = MQI.run(a, "secret_of_a(X)")

    assert {:ok, {:bindings, _}} = MQI.run(b, "secret_of_a(X)"),
           """
           MQI no longer shares a global clause store across connections.

           If this is genuinely true of the installed SWI-Prolog, one swipl per conversation
           is no longer required for isolation and `Manifold.Prolog.Engine`'s rationale
           should be revisited.
           """

    MQI.close(a)
    MQI.close(b)
  end

  test "a clause outlives the connection that asserted it", %{engine: engine} do
    {:ok, first} = Engine.connect(engine)
    {:ok, _} = MQI.run(first, "assertz(ghost(boo))")
    MQI.close(first)

    {:ok, second} = Engine.connect(engine)

    assert {:ok, {:bindings, _}} = MQI.run(second, "ghost(X)"),
           "closing a connection now cleans up its clauses; per-connection isolation may be viable"

    MQI.close(second)
  end

  test "each connection is nonetheless its own thread", %{engine: engine} do
    # The half of the picture that *is* per-connection, and the reason the shared-database
    # behaviour is surprising in the first place.
    {:ok, a} = Engine.connect(engine)
    {:ok, b} = Engine.connect(engine)

    assert {:ok, {:bindings, [[%{"args" => ["T", thread_a]}]]}} = MQI.run(a, "thread_self(T)")
    assert {:ok, {:bindings, [[%{"args" => ["T", thread_b]}]]}} = MQI.run(b, "thread_self(T)")
    assert thread_a != thread_b

    MQI.close(a)
    MQI.close(b)
  end
end
