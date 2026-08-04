defmodule Manifold.Gate do
  @moduledoc """
  The turn loop's gate: one classification of the incoming message into
  `%{new_facts: bool, needs_query: bool}` — chitchat, pure statement, pure
  question, or mixed (README, "The turn loop").

  **The model decides, under a grammar.** Each sentence is labelled `chitchat` |
  `statement` | `question` in a single call constrained by
  `Manifold.Grammar.gate/0`, and the two booleans fall out of which labels
  appeared. Sentences are still segmented mechanically on `.!?` — that is
  tokenisation, not judgement — but nothing about *meaning* is decided by a rule
  here any more.

  It has to be the model, because the distinction is semantic and the two hard
  cases are lexically indistinguishable from their opposites:

    * *"Use the clues below to find out which pet each person owns"* is a query
      with no question mark and no interrogative opening word.
    * *"Do you like cats?"* is textbook interrogative and must **not** reach the
      knowledge base — it is about the assistant, not the world. Routed there it
      produced a goal, `unknown = fail` answered it `false`, and the reply became
      a flat "No".

  A word list cannot separate those without also breaking `is`/`are`/`does`, which
  open questions and sit mid-sentence in half of all declaratives.

  `classify_lexically/1` is kept as the fallback for when the model is
  unavailable: the Prolog half works without a GGUF present (README, "Get a
  model"), so the gate must too. It is the previous implementation, and it is
  wrong in exactly the ways described above — acceptable only as a degraded mode.
  """
  require Logger

  alias Manifold.{Grammar, Prompt}
  alias Manifold.Llama.Client

  # --- the lexical fallback's word lists -------------------------------------
  #
  # Three lists, because *where* a word sits decides whether it asks anything.
  #
  # Wh-words ask wherever they appear: "find out **which** pet each person owns"
  # commissions an answer as surely as "which pet?" does. Matching these anywhere
  # is deliberately liberal, on the asymmetry in the moduledoc — a false
  # `needs_query` costs one goal that answers `false`, while a *missed* question
  # costs the entire point of the turn, since the KB is then never consulted.
  @wh ~w(who what which where when why whose whom how)

  # Auxiliaries only ask when they open the sentence, because inversion is the
  # marker: "is he mortal" asks, "he is mortal" states. Same word, and position is
  # the only thing separating a question from a fact — so these must never be
  # matched mid-sentence, or every declarative would classify as a question.
  @inverted ~w(is are was were am do does did can could will would
               should has have had may might must)

  # Imperatives that commission an answer without being interrogative at all:
  # "Use the clues below to work out who owns what", "solve this", "list the
  # mortals". A puzzle is nearly always phrased this way, never as a question.
  @imperative ~w(tell list show give find solve determine identify deduce
                 figure work compute calculate use)

  @sentence_initial @inverted ++ @imperative

  @chitchat ~w(hi hello hey yo sup hiya greetings morning evening
               thanks thank thx cheers ok okay k cool nice great
               bye goodbye night please sorry yes no yeah nope yep)

  @doc """
  Classify `message` into the two protocol booleans plus the text each half of
  the loop should actually see:

    * `new_facts` / `statements` — the declarative sentences, all that extraction
      is shown. Handing the extractor a question is how you get
      `:- mortal(socrates).` asserted from *"Is Socrates mortal?"* — the sentence
      split is what prevents it.
    * `needs_query` / `questions` — the interrogative sentences, all that goal
      generation is shown.

  A mixed message ("Socrates is human. Is he mortal?") therefore feeds each step
  only its own half, in the loop's mandated order: assert, then query.
  """
  @spec classify(String.t()) :: %{
          new_facts: boolean(),
          needs_query: boolean(),
          statements: String.t(),
          questions: String.t()
        }
  def classify(message) do
    sentences = sentences(message)

    case label(sentences) do
      {:ok, labels} -> assemble(sentences, labels)
      :error -> classify_lexically(sentences)
    end
  end

  @doc """
  The pre-model gate, kept as the degraded path when the LLM is unavailable.

  Accepts either the raw message or already-segmented sentences.
  """
  @spec classify_lexically(String.t() | [String.t()]) :: %{
          new_facts: boolean(),
          needs_query: boolean(),
          statements: String.t(),
          questions: String.t()
        }
  def classify_lexically(message) when is_binary(message),
    do: message |> sentences() |> classify_lexically()

  def classify_lexically(sentences) when is_list(sentences) do
    {questions, statements} = Enum.split_with(sentences, &question?/1)
    assemble_parts(Enum.filter(statements, &informative?/1), questions)
  end

  # --- the model call --------------------------------------------------------

  # Enough for one label per sentence with room to spare; the grammar admits
  # nothing else, so there is no risk of a long ramble to truncate.
  @label_tokens 96

  defp label([]), do: {:ok, []}

  defp label(sentences) do
    opts = [n_predict: @label_tokens, temperature: 0.0, grammar: Grammar.gate()]

    with {:ok, output} <- Client.completion(Prompt.gate(sentences), opts),
         labels = String.split(output, ~r/\s+/, trim: true),
         true <- length(labels) == length(sentences) do
      {:ok, labels}
    else
      # A count mismatch means the model labelled a different number of sentences
      # than we segmented. There is no safe way to align them, so degrade rather
      # than guess at the correspondence.
      false ->
        Logger.debug("[gate] label count did not match #{length(sentences)} sentences; falling back")
        :error

      {:error, reason} ->
        Logger.debug("[gate] model unavailable (#{inspect(reason)}); falling back to lexical")
        :error
    end
  end

  defp assemble(sentences, labels) do
    by_label = Enum.zip(labels, sentences) |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    assemble_parts(Map.get(by_label, "statement", []), Map.get(by_label, "question", []))
  end

  # `chitchat` sentences are deliberately dropped from both halves: they are
  # neither a fact to store nor a question to run, and the empty evidence block
  # they produce is what tells `respond` to simply converse.
  defp assemble_parts(statements, questions) do
    %{
      new_facts: statements != [],
      needs_query: questions != [],
      statements: Enum.join(statements, " "),
      questions: Enum.join(questions, " ")
    }
  end

  # Sentence boundaries on .!? — periods inside numbers are not a concern here
  # because this sees English, not Prolog.
  defp sentences(message) do
    ~r/(?<=[.!?])\s+/
    |> Regex.split(String.trim(message))
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp question?(sentence) do
    words = words(sentence)

    String.ends_with?(sentence, "?") or
      List.first(words) in @sentence_initial or
      Enum.any?(words, &(&1 in @wh))
  end

  # A statement carries facts unless it is pure social noise ("hi", "thanks!").
  defp informative?(sentence) do
    words = words(sentence)
    words != [] and not Enum.all?(words, &(&1 in @chitchat))
  end

  defp words(sentence) do
    sentence
    |> String.downcase()
    |> String.replace(~r/[^\p{L}\p{N}\s]/u, " ")
    |> String.split(~r/\s+/, trim: true)
  end
end
