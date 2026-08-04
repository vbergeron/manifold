defmodule Manifold.Prompt do
  @moduledoc """
  Prompt construction for the LLM steps of the turn loop.

  Kept out of the callers so prompts are iterable and testable in isolation.
  All prompts target Qwen's ChatML template and are meant to be paired with a
  GBNF grammar (`Manifold.Grammar.prolog/0`) — the grammar enforces *syntax*,
  the prompt steers *structure and vocabulary*.
  """

  @gate_system """
  You label each numbered sentence of a message sent to a knowledge-base assistant.

  Labels:
  - statement — asserts something about the world that could be stored as a fact. "Socrates is a human", "Bill's pet lives in a bowl".
  - question — asks for something to be worked out from stored knowledge. This includes instructions to do so, which are not phrased as questions: "Is Socrates mortal?", "Use the clues below to find out which pet each person owns", "List the mortals".
  - chitchat — social talk, or anything about the assistant itself rather than about the world. "hi", "thanks", "how are you today?", "what is your name?", "do you like cats?".

  Decide by what the sentence is *for*, not by its punctuation: a question mark does not make something a question, and an instruction without one still is.

  Output one label per sentence, in order, separated by single spaces. Nothing else.
  """

  # The shots that matter are the ones that separate the two easily-confused
  # pairs: an imperative that *is* a query, and a second-person question that is
  # *not* one. Both were misrouted by the lexical gate this replaces.
  @gate_examples [
    {["Socrates is a human.", "All humans are mortal.", "Is Socrates mortal?"], "statement statement question"},
    {["how are you today?"], "chitchat"},
    {["Do you like cats?"], "chitchat"},
    {[
       "Jane, Bill and Kelly each have one pet.",
       "Use the clues below to find out which pet each person owns.",
       "Clue 1 : Kelly's pet does not have a beak."
     ], "statement question statement"},
    {["thanks!", "Who is mortal?"], "chitchat question"},
    {["A whale is a mammal, not a fish."], "statement"}
  ]

  @doc """
  Build the gate prompt (ChatML) for an already-segmented message.

  Paired with `Manifold.Grammar.gate/0`, which restricts the output to the three
  labels — so the model decides *meaning* and the grammar guarantees the shape,
  the same division of labour as the Prolog steps.
  """
  @spec gate([String.t()]) :: String.t()
  def gate(sentences) do
    shots =
      Enum.map_join(@gate_examples, "", fn {ss, out} ->
        turn("user", sentence_block(ss)) <> turn("assistant", out)
      end)

    turn("system", @gate_system) <>
      shots <>
      turn("user", sentence_block(sentences)) <>
      open("assistant")
  end

  defp sentence_block(sentences) do
    sentences
    |> Enum.with_index(1)
    |> Enum.map_join("\n", fn {s, i} -> "#{i}. #{s}" end)
  end

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
  - An `unanswered` line means the knowledge base holds nothing bearing on the question. That is NOT a "no": say you do not know it yet and ask the user to tell you. Never guess the answer.
  - Answer in your own words. Never echo the Evidence block's own vocabulary — not `true`, `false`, `unanswered`, and no Prolog.
  - If a CONTRADICTION is listed, lead with it: name the two things that conflict and ask the user which one holds.
  - Reply in one or two short sentences of plain English. No Prolog syntax, no lists, no preamble, no restating the question.
  """

  # {evidence lines, message, reply} — one shot per evidence shape.
  #
  # This step is ungrammared, so the prompt is the only thing holding the output
  # register. With rules alone a 3B model degrades into *copying*: it answered
  # "true", "false", even "unanswered", reading the evidence block's own vocabulary
  # back instead of writing English. Shots anchor that far more reliably than any
  # further rule — and the two other Prolog prompts already work this way.
  @respond_examples [
    {["- query: mortal(socrates) => true"], "Is Socrates mortal?",
     "Yes — Socrates is human, and every human is mortal."},
    {["- query: mortal(zeus) => false"], "Is Zeus mortal?",
     "Not as far as I know — nothing I've been told makes Zeus mortal."},
    {["- unanswered: nothing stored bears on capital(france, X)"], "What is the capital of France?",
     "I don't know that yet. Tell me and I'll remember it."},
    {["- learned: human(plato).", "- learned: mortal(X) :- human(X)."], "Plato is a person. All people are mortal.",
     "Noted — Plato is human, and I'll treat every human as mortal from now on."},
    {["- CONTRADICTION: :- whale(A), fish(A). is violated (A = willy), offending clause: fish(willy)."],
     "Willy is a fish.",
     "That clashes with what I already have: Willy is a whale, and a whale cannot be a fish. Which of the two should I keep?"},
    {[], "how are you today?", "I'm well, thanks for asking — what can I help you with?"}
  ]

  @doc """
  Build the free-form response prompt (ChatML, **no grammar** — this is the one
  step that generates prose).

  Fields:

    * `:message`    — the user's message this turn
    * `:history`    — earlier transcript messages (`%{kind: "user" | "assistant", text: …}`)
    * `:clauses`    — clause texts learned this turn
    * `:answers`    — `%{goal: …, answer: …}` results from the query phase
    * `:unanswered` — `%{goal: …, missing: […]}` goals the KB could not speak to
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

    shots =
      Enum.map_join(@respond_examples, "", fn {lines, message, reply} ->
        turn("user", evidence_text(lines, message)) <> turn("assistant", reply)
      end)

    turn("system", @respond_system) <>
      shots <>
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

    # Goals the knowledge base could not speak to. Distinguishing these from a
    # `false` is the difference between "no" and "I don't know yet": with
    # `unknown = fail` set on the engine, both look identical by the time an
    # answer comes back, so the turn loop tells us which it was.
    # Phrased as prose rather than a shouty label: at 3B the model copies anything
    # that looks like a tag straight into its reply ("NO KNOWLEDGE"), so the line
    # has to read as something it would be harmless to echo.
    unanswered =
      Enum.map(Map.get(fields, :unanswered, []), fn
        %{goal: nil} -> "- unanswered: nothing has been stated to the knowledge base yet"
        %{goal: goal, missing: []} -> "- unanswered: nothing stored bears on #{goal}"
        %{goal: goal, missing: missing} -> "- unanswered: #{goal} — no #{Enum.join(missing, ", ")} is stored"
      end)

    violations =
      Enum.map(Map.get(fields, :violations, []), fn v ->
        "- CONTRADICTION: #{v.constraint} is violated#{witness_text(v.witness)}#{offending_text(v.offending)}"
      end)

    evidence_text(learned ++ answers ++ unanswered ++ violations, fields.message)
  end

  # Shared by the shots and the live turn, so an example is byte-identical in shape
  # to what the model is about to be asked about.
  defp evidence_text([], message),
    do: "Evidence:\n(nothing new — answer conversationally, and do not claim to know facts)\n\nMessage: #{message}"

  defp evidence_text(lines, message),
    do: "Evidence:\n#{Enum.join(lines, "\n")}\n\nMessage: #{message}"

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
