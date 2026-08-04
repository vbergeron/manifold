# Prompt brittleness harness. Boots once, runs a battery of varied inputs through
# the extract prompt under the grammar, and shows the Prolog + whether it asserts.
# Run: mise exec -- mix run scripts/prompt_eval.exs
wait = fn wait, label, fun, n ->
  cond do
    fun.() -> :ok
    n <= 0 -> raise "#{label} not ready"
    true -> Process.sleep(1000); wait.(wait, label, fun, n - 1)
  end
end

wait.(wait, "prolog", &Manifold.Prolog.Server.ready?/0, 30)
wait.(wait, "llama", &Manifold.Llama.Server.ready?/0, 120)

# {input, known_predicates} — the last few probe vocabulary reuse.
cases = [
  {"Socrates is a human. All humans are mortal.", []},
  {"Bob loves Carol and Carol loves Dave.", []},
  {"Paris is the capital of France.", []},
  {"Alice is 30 years old.", []},
  {"Tom is taller than Jerry.", []},
  {"A whale is a mammal, not a fish.", []},
  {"Tweety is a bird but does not fly.", []},
  {"Every student who studied passed.", []},
  # vocab reuse: KB already knows human/1 — should reuse it, not invent person/1
  {"Plato is a person.", ["human/1", "mortal/1"]}
]

Enum.each(cases, fn {input, preds} ->
  IO.puts("\n" <> String.duplicate("─", 70))
  IO.puts("IN:   #{input}")
  IO.puts("KB:   #{if preds == [], do: "(empty)", else: Enum.join(preds, ", ")}")
  prompt = Manifold.Prompt.extract(input, preds)

  {:ok, out} =
    Manifold.Llama.Client.completion(prompt,
      grammar: Manifold.Grammar.prolog(),
      n_predict: 200,
      temperature: 0.2
    )

  IO.puts("OUT:\n" <> (out |> String.trim() |> String.replace("\n", "\n      ") |> then(&("      " <> &1))))

  # Does it actually load into a KB?
  clauses = out |> String.split(".", trim: true) |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
  {:ok, c} = Manifold.start_conversation()
  results = Manifold.assert(c, clauses)
  IO.puts("LOAD: #{inspect(results)}")
end)

IO.puts("\n" <> String.duplicate("═", 70))
IO.puts("CONSISTENCY CHECK via integrity constraint")
{:ok, kb} = Manifold.start_conversation()
Manifold.assert(kb, ["mammal(X) :- whale(X)", ":- whale(A), fish(A)", "whale(willy)"])
# willy is a whale, no fish claim yet → constraint body should NOT be provable.
IO.inspect(Manifold.query(kb, "whale(A), fish(A)"), label: "before: constraint violated?")
# Now a contradicting fact arrives.
Manifold.assert(kb, ["fish(willy)"])
IO.inspect(Manifold.query(kb, "whale(A), fish(A)"), label: "after fish(willy): violated?")

IO.puts("\ndone")
