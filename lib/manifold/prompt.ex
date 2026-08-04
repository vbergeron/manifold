defmodule Manifold.Prompt do
  @moduledoc """
  Prompt construction for the LLM steps of the turn loop.

  Kept out of the callers so prompts are iterable and testable in isolation.
  All prompts target Qwen's ChatML template and are meant to be paired with a
  GBNF grammar (`Manifold.Grammar.prolog/0`) — the grammar enforces *syntax*,
  the prompt steers *structure and vocabulary*.
  """

  @extract_system """
  You convert English statements into Prolog clauses for a knowledge base.

  Guidelines:
  - Represent relations as predicates WITH arguments: human(socrates), loves(bob, carol), capital(paris, france).
  - "all/every X are Y" becomes a rule with a variable: mortal(X) :- human(X).
  - An attribute with a value becomes a binary predicate: age(alice, 30).
  - Use singular predicate names (human, not humans).
  - A fact must be GROUND — no uppercase variables. Only rules contain variables.
  - VOCABULARY: if a word means the same as one of the Existing predicates (e.g. "person" when human/1 exists), reuse that predicate; never coin a synonym for one that already exists.
  - A negative statement ("X is not a Y", "Z does not P") becomes an integrity constraint with an empty head, meaning "this must never hold": `:- whale(A), fish(A).` or `:- flies(tweety).` Never use not/1.
  - Output ONLY Prolog clauses, one per line, each ending with a period. No prose.
  """

  # {existing predicates, statement, expected clauses} — the middle one teaches
  # synonym→existing-predicate reuse, which listing alone failed to trigger.
  @extract_examples [
    {"none yet", "Alice is a dog. All dogs are animals.", "dog(alice).\nanimal(X) :- dog(X)."},
    {"human/1, mortal/1", "Plato is a person.", "human(plato)."},
    {"none yet", "Bob loves Carol. Carol is 25 years old.", "loves(bob, carol).\nage(carol, 25)."},
    {"mammal/1", "A whale is a mammal, but not a fish.", "mammal(X) :- whale(X).\n:- whale(A), fish(A)."}
  ]

  @doc """
  Build the fact-extraction prompt (ChatML) for `message`.

  `known_predicates` is a list of `"name/arity"` strings describing what is
  already in the KB. It is injected into every turn (system rules + each shot +
  the live message) so the model reuses that vocabulary instead of coining
  synonyms — the main defence against cross-turn predicate drift.
  """
  @spec extract(String.t(), [String.t()]) :: String.t()
  def extract(message, known_predicates \\ []) do
    shots =
      Enum.map_join(@extract_examples, "", fn {preds, stmt, out} ->
        turn("user", user_block(preds, stmt)) <> turn("assistant", out)
      end)

    turn("system", @extract_system) <>
      shots <>
      turn("user", user_block(schema(known_predicates), message)) <>
      open("assistant")
  end

  @goals_system """
  You turn a question into Prolog goals to run against a knowledge base.

  Guidelines:
  - Output one goal per line, each ending with a period. One goal is usually enough.
  - Use ONLY predicates from Existing predicates — never invent one, never guess an arity.
  - A yes/no question becomes a ground goal: mortal(socrates).
  - A who/what/which question becomes a goal with an uppercase variable: human(X).
  - Several conditions become a conjunction: human(X), age(X, 30).
  - Output ONLY the goal(s). No prose, no explanation.
  """

  @goals_examples [
    {"human/1, mortal/1", "Is Socrates mortal?", "mortal(socrates)."},
    {"human/1, age/2", "Who is human?", "human(X)."},
    {"loves/2", "Does Bob love Carol?", "loves(bob, carol)."},
    {"dog/1, animal/1, age/2", "Which animals are older than nothing?", "animal(X)."}
  ]

  @doc """
  Build the goal-generation prompt (ChatML) for `question`.

  Runs *after* assertion, so `known_predicates` already includes anything this
  turn contributed — the read-after-write dependency the turn loop guarantees.
  Paired with the same Prolog grammar as `extract/2`; the caller strips the
  trailing period to get a runnable goal.
  """
  @spec goals(String.t(), [String.t()]) :: String.t()
  def goals(question, known_predicates \\ []) do
    shots =
      Enum.map_join(@goals_examples, "", fn {preds, q, out} ->
        turn("user", question_block(preds, q)) <> turn("assistant", out)
      end)

    turn("system", @goals_system) <>
      shots <>
      turn("user", question_block(schema(known_predicates), question)) <>
      open("assistant")
  end

  @respond_system """
  You are Manifold, an assistant whose memory is a live Prolog knowledge base.

  - The Evidence block is ground truth read out of that knowledge base. Never contradict it and never invent facts that are not in it.
  - A query answered `false` means "not derivable from what I know" — say "no" or "not as far as I know", never "impossible".
  - If a CONTRADICTION is listed, lead with it: name the two things that conflict and ask the user which one holds.
  - Reply in one or two short sentences of plain English. No Prolog syntax, no lists, no preamble, no restating the question.
  """

  @doc """
  Build the free-form response prompt (ChatML, **no grammar** — this is the one
  step that generates prose).

  Fields:

    * `:message`    — the user's message this turn
    * `:history`    — earlier transcript messages (`%{kind: "user" | "assistant", text: …}`)
    * `:clauses`    — clause texts learned this turn
    * `:answers`    — `%{goal: …, answer: …}` results from the query phase
    * `:violations` — `%{constraint: …, witness: …, offending: …}` from the check phase

  The evidence block is what grounds the reply; when it is empty the model is
  told so explicitly, which is what keeps chitchat turns from hallucinating
  knowledge-base content.
  """
  @spec respond(map()) :: String.t()
  def respond(fields) do
    history =
      fields
      |> Map.get(:history, [])
      |> Enum.map_join("", fn m -> turn(m.kind, m.text) end)

    turn("system", @respond_system) <>
      history <>
      turn("user", evidence_block(fields)) <>
      open("assistant")
  end

  defp evidence_block(fields) do
    learned = Enum.map(Map.get(fields, :clauses, []), &"- learned: #{&1}")

    answers =
      Enum.map(Map.get(fields, :answers, []), fn a ->
        "- query: #{a.goal} => #{answer_text(a.answer)}"
      end)

    violations =
      Enum.map(Map.get(fields, :violations, []), fn v ->
        "- CONTRADICTION: #{v.constraint} is violated#{witness_text(v.witness)}#{offending_text(v.offending)}"
      end)

    evidence =
      case learned ++ answers ++ violations do
        [] -> "(nothing new — answer conversationally, and do not claim to know facts)"
        lines -> Enum.join(lines, "\n")
      end

    "Evidence:\n#{evidence}\n\nMessage: #{fields.message}"
  end

  defp answer_text(true), do: "true"
  defp answer_text(false), do: "false"

  defp answer_text(%{bindings: solutions}) do
    solutions
    |> Enum.map_join("; ", fn sol -> Enum.map_join(sol, ", ", fn {k, v} -> "#{k} = #{v}" end) end)
    |> case do
      "" -> "true"
      text -> text
    end
  end

  defp witness_text(nil), do: ""
  defp witness_text(w), do: " (#{Enum.map_join(w, ", ", fn {k, v} -> "#{k} = #{v}" end)})"

  defp offending_text(nil), do: ""
  defp offending_text(clause), do: ", offending clause: #{clause}"

  defp user_block(schema, statement),
    do: "Existing predicates: #{schema}.\nStatement: #{statement}"

  defp question_block(schema, question),
    do: "Existing predicates: #{schema}.\nQuestion: #{question}"

  defp schema([]), do: "none yet"
  defp schema(preds) when is_binary(preds), do: preds
  defp schema(preds), do: Enum.join(preds, ", ")

  defp turn(role, content), do: open(role) <> content <> "<|im_end|>\n"
  defp open(role), do: "<|im_start|>#{role}\n"
end
