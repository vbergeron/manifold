defmodule Manifold.PromptTest do
  use ExUnit.Case, async: true

  alias Manifold.Grammar
  alias Manifold.Prompt

  # These assert *properties*, never exact prompt text. The prompts are iterated constantly
  # — three separate times in one session — and a test pinned to their wording would fail on
  # every improvement while telling you nothing about correctness. What must hold is that
  # the caller's data reaches the model and that each evidence shape renders.

  describe "extract/2" do
    test "the message reaches the model" do
      assert Prompt.extract("Socrates is a human.") =~ "Socrates is a human."
    end

    test "known predicates are injected so vocabulary does not drift" do
      # This is the main defence against the model coining `person/1` when `human/1` exists.
      prompt = Prompt.extract("Plato is a person.", ["human/1", "mortal/1"])
      assert prompt =~ "human/1"
      assert prompt =~ "mortal/1"
    end

    test "an empty knowledge base is stated rather than left blank" do
      assert Prompt.extract("Anything.", []) =~ "none yet"
    end
  end

  describe "goals/2" do
    test "the question and the available vocabulary both reach the model" do
      prompt = Prompt.goals("Is Socrates mortal?", ["mortal/1"])
      assert prompt =~ "Is Socrates mortal?"
      assert prompt =~ "mortal/1"
    end
  end

  describe "gate/1" do
    test "sentences arrive numbered, so labels can be zipped back onto them" do
      prompt = Prompt.gate(["Socrates is a human.", "Is Socrates mortal?"])
      assert prompt =~ "1. Socrates is a human."
      assert prompt =~ "2. Is Socrates mortal?"
    end

    test "the three labels the grammar permits are all described" do
      prompt = Prompt.gate(["hi"])
      for label <- ~w(statement question chitchat), do: assert(prompt =~ label)
    end
  end

  describe "respond/1" do
    test "an empty evidence block tells the model to converse rather than invent" do
      # This is the path that keeps chitchat from hallucinating knowledge-base content.
      prompt = Prompt.respond(%{message: "how are you today?"})
      assert prompt =~ "nothing new"
      assert prompt =~ "how are you today?"
    end

    test "query answers render as evidence" do
      prompt =
        Prompt.respond(%{
          message: "Is Socrates mortal?",
          answers: [%{goal: "mortal(socrates)", answer: true}]
        })

      assert prompt =~ "mortal(socrates)"
    end

    test "each unanswered shape renders, and none leaks a bare tag" do
      # The model copies anything that looks like a label straight into its reply, which is
      # how a user once got the literal word "unanswered" as an answer. The lines must read
      # as prose that would be harmless if echoed.
      for unanswered <- [
            %{goal: nil, missing: []},
            %{goal: "mortal(socrates)", missing: []},
            %{goal: "mortal(socrates)", missing: ["mortal/1"]}
          ] do
        prompt = Prompt.respond(%{message: "Is Socrates mortal?", unanswered: [unanswered]})
        assert prompt =~ "unanswered"
        refute prompt =~ "NO KNOWLEDGE", "shouty tags get parroted back verbatim"
      end
    end

    test "a contradiction renders with its witness and the offending clause" do
      prompt =
        Prompt.respond(%{
          message: "Willy is a fish.",
          violations: [
            %{
              constraint: ":- whale(A), fish(A).",
              witness: %{"A" => "willy"},
              offending: "fish(willy)."
            }
          ]
        })

      assert prompt =~ "CONTRADICTION"
      assert prompt =~ "willy"
      assert prompt =~ "fish(willy)."
    end

    test "learned clauses render" do
      prompt = Prompt.respond(%{message: "Socrates is human.", clauses: ["human(socrates)."]})
      assert prompt =~ "human(socrates)."
    end

    test "history is included so pronouns and tone stay coherent" do
      prompt =
        Prompt.respond(%{
          message: "Is he mortal?",
          history: [%{kind: "user", text: "Socrates is a human."}]
        })

      assert prompt =~ "Socrates is a human."
    end
  end

  describe "grammars" do
    test "the Prolog grammar admits the clause forms the loop depends on" do
      grammar = Grammar.prolog()
      assert grammar =~ "root"
      assert grammar =~ "constraint", "negation is represented as a headless clause"
      assert grammar =~ "list", "generate-and-test needs list syntax"
    end

    test "the gate grammar admits exactly the three labels and nothing else" do
      grammar = Grammar.gate()
      for label <- ~w(chitchat statement question), do: assert(grammar =~ label)
    end
  end
end
