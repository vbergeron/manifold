defmodule Manifold.Gate do
  @moduledoc """
  The turn loop's gate: one classification of the incoming message into
  `%{new_facts: bool, needs_query: bool}` — chitchat, pure statement, pure
  question, or mixed (README, "The turn loop").

  This implementation is **lexical, not learned**: it splits the message into
  sentences and asks of each whether it is interrogative. That keeps the gate
  free and instant, and it is the one step where being wrong is cheap — a false
  `new_facts` costs one grammar-constrained extraction that yields nothing
  useful, a false `needs_query` costs one goal that answers `false`.

  Swapping in an LLM gate is a `classify/1` rewrite and nothing else: the rest of
  the loop only reads the two booleans.
  """

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
    {questions, statements} = message |> sentences() |> Enum.split_with(&question?/1)
    statements = Enum.filter(statements, &informative?/1)

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
