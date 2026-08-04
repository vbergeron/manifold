# Smoke test: boot the app, drive a doubled conversation end-to-end against a real
# swipl MQI engine. Run with: mix run scripts/smoke.exs
require Logger

# There is nothing to wait for any more: Prolog is not a shared sidecar, so an engine is
# launched by the conversation itself and `open_conversation` does not return until it is
# ready. That opening succeeds at all is the readiness check.
IO.puts("\n== readiness ==")
IO.inspect(Manifold.ready?(), label: "sidecars")

{:ok, _id, conv} = Manifold.open_conversation(nil)
IO.puts("\n== assert into KB ==")
IO.inspect(Manifold.assert(conv, ["human(socrates)", "mortal(X) :- human(X)"]), label: "assert")

IO.puts("\n== query ==")
IO.inspect(Manifold.query(conv, "mortal(socrates)"), label: "mortal(socrates)?")
IO.inspect(Manifold.query(conv, "mortal(zeus)"), label: "mortal(zeus)?")
IO.inspect(Manifold.query(conv, "human(X)"), label: "human(X)?")
IO.inspect(Manifold.Conversation.kb_size(conv), label: "kb_size")

IO.puts("\n== runaway-query kill switch, level 1: per-query timeout ==")
IO.inspect(Manifold.query(conv, "loop(0)", 1), label: "loop with no clause")
IO.inspect(Manifold.assert(conv, ["loop(N) :- N1 is N+1, loop(N1)"]), label: "assert loop/1")
IO.inspect(Manifold.query(conv, "loop(0)", 1), label: "infinite loop, 1s cap")

IO.puts("\n== kill switch, level 3: destroy the engine, keep the knowledge base ==")
# This is the claim the README rests on, and it only holds with one engine per
# conversation: killing a *shared* server would take every other conversation's KB with
# it. Here the conversation dies with its engine and rehydrates from its own log.
{:ok, id, conv2} = Manifold.open_conversation(nil)
Manifold.assert(conv2, ["human(plato)", "mortal(X) :- human(X)"])
before = Manifold.Conversation.kb_size(conv2)
IO.inspect(before, label: "kb_size before kill")

:ok = Manifold.kill_engine(id)
Process.sleep(1_000)

{:ok, ^id, revived} = Manifold.open_conversation(id)
IO.inspect(Manifold.Conversation.kb_size(revived), label: "kb_size after kill+rehydrate")
IO.inspect(Manifold.query(revived, "mortal(plato)"), label: "inference on the new engine")
:ok = Manifold.stop_conversation(id)

IO.puts("\n== done ==")
