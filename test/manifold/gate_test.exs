defmodule Manifold.GateTest do
  use ExUnit.Case, async: true

  alias Manifold.Gate

  # Only the lexical path is tested here. `classify/1` asks the model, so it belongs to the
  # smoke tier — but the lexical classifier is the degraded path used whenever no GGUF is
  # loaded, so it has to keep working on its own.

  defp classify(text), do: Gate.classify_lexically(text)

  describe "declaratives stay statements" do
    # This is the regression that matters most. Auxiliaries like `is`/`are`/`does` open
    # questions *and* sit mid-sentence in half of all declaratives, so a classifier that
    # matches them anywhere labels every fact as a question — which routes facts away from
    # extraction and silently empties the knowledge base.
    for sentence <- [
          "Socrates is a human.",
          "All humans are mortal.",
          "Tweety is a bird but does not fly.",
          "A whale is a mammal, not a fish.",
          "Bob loves Carol and Carol loves Dave.",
          "Alice is 30 years old.",
          "Clue 2 : Bill's pet lives in a bowl."
        ] do
      test "#{inspect(sentence)} is a statement, not a question" do
        gate = classify(unquote(sentence))
        assert gate.new_facts, "should have been offered to extraction"
        refute gate.needs_query, "a declarative must not be routed to the knowledge base"
      end
    end
  end

  describe "questions" do
    test "a trailing question mark is enough" do
      gate = classify("Is Socrates mortal?")
      assert gate.needs_query
      refute gate.new_facts
    end

    test "an interrogative opening word is enough without punctuation" do
      assert classify("Who is human").needs_query
    end

    test "an imperative that commissions an answer counts, though it is not interrogative" do
      # A puzzle is nearly always phrased this way and never as a question.
      assert classify("Solve the puzzle.").needs_query
      assert classify("List the mortals.").needs_query
    end

    test "an embedded wh-word counts, since it asks wherever it sits" do
      gate = classify("Use the clues below to find out which pet each person owns.")
      assert gate.needs_query
    end
  end

  describe "mixed messages" do
    test "each half is routed to its own step, and only its own" do
      gate = classify("Socrates is a human. All humans are mortal. Is Socrates mortal?")

      assert gate.new_facts and gate.needs_query
      assert gate.questions == "Is Socrates mortal?"
      assert gate.statements == "Socrates is a human. All humans are mortal."

      # Handing the extractor a question is how `:- mortal(socrates).` gets asserted from
      # "Is Socrates mortal?"; the split is what prevents it.
      refute gate.statements =~ "Is Socrates"
    end
  end

  describe "chitchat" do
    test "social noise produces neither facts nor queries" do
      for text <- ["hi", "thanks!", "ok", "hello"] do
        gate = classify(text)
        refute gate.new_facts, "#{text} should not reach extraction"
        refute gate.needs_query, "#{text} should not reach the knowledge base"
      end
    end
  end

  describe "accepting pre-segmented input" do
    test "a list of sentences classifies the same as the joined string" do
      sentences = ["Socrates is a human.", "Is Socrates mortal?"]
      assert Gate.classify_lexically(sentences) == classify(Enum.join(sentences, " "))
    end
  end

  test "an empty message asks for nothing" do
    gate = classify("")
    refute gate.new_facts
    refute gate.needs_query
  end
end
