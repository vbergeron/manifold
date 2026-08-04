# Smoke test: boot the app, drive a doubled conversation end-to-end against the
# real supervised swipl MQI server. Run with: mix run scripts/smoke.exs
require Logger

wait_ready = fn wait_ready, n ->
  cond do
    Manifold.Prolog.Server.ready?() -> :ok
    n <= 0 -> raise "prolog server never became ready"
    true -> Process.sleep(200); wait_ready.(wait_ready, n - 1)
  end
end

wait_ready.(wait_ready, 50)
IO.puts("\n== readiness ==")
IO.inspect(Manifold.ready?(), label: "sidecars")

{:ok, conv} = Manifold.start_conversation()
IO.puts("\n== assert into KB ==")
IO.inspect(Manifold.assert(conv, ["human(socrates)", "mortal(X) :- human(X)"]), label: "assert")

IO.puts("\n== query ==")
IO.inspect(Manifold.query(conv, "mortal(socrates)"), label: "mortal(socrates)?")
IO.inspect(Manifold.query(conv, "mortal(zeus)"), label: "mortal(zeus)?")
IO.inspect(Manifold.query(conv, "human(X)"), label: "human(X)?")
IO.inspect(Manifold.Conversation.kb_size(conv), label: "kb_size")

IO.puts("\n== runaway-query kill switch (1s timeout on infinite loop) ==")
IO.inspect(Manifold.query(conv, "loop(0)", 1), label: "loop with no clause")
IO.inspect(Manifold.assert(conv, ["loop(N) :- N1 is N+1, loop(N1)"]), label: "assert loop/1")
IO.inspect(Manifold.query(conv, "loop(0)", 1), label: "infinite loop, 1s cap")

IO.puts("\n== done ==")
