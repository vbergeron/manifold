# Validate the GBNF-constrained Prolog generation path end to end:
# boot -> wait for the llama.cpp server to load the model -> generate Prolog
# under the grammar -> assert it into a conversation KB -> query it.
# Run with: mise exec -- mix run scripts/gen.exs
require Logger

wait = fn wait, label, fun, n ->
  cond do
    fun.() -> :ok
    n <= 0 -> raise "#{label} never became ready"
    true -> Process.sleep(1000); wait.(wait, label, fun, n - 1)
  end
end

IO.puts("waiting for the model (load can take ~10-20s on CPU)...")
# No Prolog wait: engines are per-conversation and boot on demand in ~90 ms.
wait.(wait, "llama", &Manifold.Llama.Server.ready?/0, 120)
IO.inspect(Manifold.ready?(), label: "ready")

# Qwen ChatML prompt; the grammar forces the completion to be valid Prolog.
prompt = """
<|im_start|>system
You translate English into Prolog. Use predicates WITH arguments, e.g. human(socrates). Encode "all X are Y" as a rule with :- and a variable, e.g. mortal(X) :- human(X). Lowercase predicates and constants; uppercase variables. Output only Prolog clauses, one per line.<|im_end|>
<|im_start|>user
Alice is a dog. All dogs are animals.<|im_end|>
<|im_start|>assistant
dog(alice).
animal(X) :- dog(X).<|im_end|>
<|im_start|>user
Socrates is a human. All humans are mortal. Zeus is a god.<|im_end|>
<|im_start|>assistant
"""

IO.puts("\n== generating Prolog under GBNF grammar ==")
{:ok, prolog} = Manifold.Llama.Client.completion(prompt, grammar: Manifold.Grammar.prolog(), n_predict: 256, temperature: 0.2)
IO.puts(prolog)

# Feed whatever it produced into a KB and reason over it.
clauses = prolog |> String.split(".", trim: true) |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
{:ok, conv} = Manifold.start_conversation()
IO.inspect(Manifold.assert(conv, clauses), label: "\nassert")
IO.inspect(Manifold.query(conv, "mortal(socrates)"), label: "mortal(socrates)?")
IO.puts("\n== done ==")
