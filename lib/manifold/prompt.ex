defmodule Manifold.Prompt do
  @moduledoc """
  Prompt construction for the LLM steps of the turn loop.

  Kept out of the callers so prompts are iterable and testable in isolation.
  All prompts target Qwen's ChatML template and are meant to be paired with a
  GBNF grammar (`Manifold.Grammar.prolog/0`) — the grammar enforces *syntax*,
  the prompt steers *structure and vocabulary*.

  Every step's prompt is split across two files in `priv/prompts/`:
    * `<step>.txt`         — the system instruction (prose, patterns, decision rules)
    * `<step>_shots.chatml`— the few-shot turns, raw ChatML, byte-identical to
                             what the model actually sees

  Both are loaded at compile time via `@external_resource` so `mix compile`
  picks up edits automatically. Neither file should be touched to change logic —
  that lives in this module's builder functions.
  """

  @external_resource "priv/prompts/gate.txt"
  @external_resource "priv/prompts/gate_shots.chatml"
  @external_resource "priv/prompts/extract.txt"
  @external_resource "priv/prompts/extract_shots.chatml"
  @external_resource "priv/prompts/goals.txt"
  @external_resource "priv/prompts/goals_shots.chatml"
  @external_resource "priv/prompts/respond.txt"
  @external_resource "priv/prompts/respond_shots.chatml"

  @gate_system File.read!("priv/prompts/gate.txt")
  @gate_shots File.read!("priv/prompts/gate_shots.chatml")

  @doc """
  Build the gate prompt (ChatML) for an already-segmented message.

  Paired with `Manifold.Grammar.gate/0`, which restricts the output to the three
  labels — so the model decides *meaning* and the grammar guarantees the shape,
  the same division of labour as the Prolog steps.

  The few-shot examples live in `priv/prompts/gate_shots.chatml` — ten shots
  covering the full pattern set documented in `gate.txt`, including the hard
  cases (imperative-as-statement, imperative-as-question, rhetorical assertion,
  back-reference).
  """
  @spec gate([String.t()]) :: String.t()
  def gate(sentences) do
    turn("system", @gate_system) <>
      @gate_shots <>
      turn("user", sentence_block(sentences)) <>
      open("assistant")
  end

  defp sentence_block(sentences) do
    sentences
    |> Enum.with_index(1)
    |> Enum.map_join("\n", fn {s, i} -> "#{i}. #{s}" end)
  end

  @extract_system File.read!("priv/prompts/extract.txt")
  @extract_shots File.read!("priv/prompts/extract_shots.chatml")

  @doc """
  Build the fact-extraction prompt (ChatML) for `message`.

  `known_predicates` is a list of `"name/arity"` strings describing what is
  already in the KB. It is injected into the live turn so the model reuses
  that vocabulary instead of coining synonyms — the main defence against
  cross-turn predicate drift.

  The few-shot examples live in `priv/prompts/extract_shots.chatml` — one shot
  per modelling pattern, covering all eleven patterns documented in `extract.txt`.
  Edit that file to add or replace shots without touching this module.
  """
  @spec extract(String.t(), [String.t()]) :: String.t()
  def extract(message, known_predicates \\ []) do
    turn("system", @extract_system) <>
      @extract_shots <>
      turn("user", user_block(schema(known_predicates), message)) <>
      open("assistant")
  end

  @goals_system File.read!("priv/prompts/goals.txt")
  @goals_shots File.read!("priv/prompts/goals_shots.chatml")

  @doc """
  Build the goal-generation prompt (ChatML) for `question`.

  Runs *after* assertion, so `known_predicates` already includes anything this
  turn contributed — the read-after-write dependency the turn loop guarantees.
  Paired with the same Prolog grammar as `extract/2`; the caller strips the
  trailing period to get a runnable goal.

  The few-shot examples live in `priv/prompts/goals_shots.chatml`, covering all
  seven patterns from `goals.txt`: polar/wh/attribute questions, superlatives,
  multi-condition decomposition (separate goals, shared variable), set-difference
  decomposition (both sides retrieved, no \+), vocabulary reuse, unknown
  predicates, and multi-question.

  Note: the grammar (`prolog.gbnf`) constrains goals to a single term — `fact ::=
  term`. Conjunction and `\+` are only reachable inside a rule body (`term :- body`)
  or constraint (`:-  body`), never as standalone goals. Goals are therefore always
  simple lookups; multi-condition questions decompose into several goals.
  """
  @spec goals(String.t(), [String.t()]) :: String.t()
  def goals(question, known_predicates \\ []) do
    turn("system", @goals_system) <>
      @goals_shots <>
      turn("user", question_block(schema(known_predicates), question)) <>
      open("assistant")
  end

  @respond_system File.read!("priv/prompts/respond.txt")
  @respond_shots File.read!("priv/prompts/respond_shots.chatml")

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

  The evidence block grounds the reply; when it is empty the model is told so
  explicitly, keeping chitchat turns from hallucinating KB content.

  The few-shot examples live in `priv/prompts/respond_shots.chatml` — one shot
  per evidence shape: learned fact, learned rule, learned constraint, learned
  enumeration, true query, false query, single-binding, multi-binding, multi-
  variable binding, unanswered (missing predicate), unanswered (nothing stored),
  unanswered (empty KB), contradiction with witness, contradiction without
  witness, mixed evidence, and empty evidence (×2).
  """
  @spec respond(map()) :: String.t()
  def respond(fields) do
    history =
      fields
      |> Map.get(:history, [])
      |> Enum.map_join("", fn m -> turn(m.kind, m.text) end)

    turn("system", @respond_system) <>
      @respond_shots <>
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
