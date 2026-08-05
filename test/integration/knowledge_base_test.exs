defmodule Manifold.Integration.KnowledgeBaseTest do
  use Manifold.EngineCase, async: false

  setup do
    {_id, conv} = open_conversation!()
    {:ok, conv: conv}
  end

  describe "inference" do
    test "an answer can be derived rather than stored", %{conv: conv} do
      Conversation.assert(conv, ["human(socrates)", "mortal(X) :- human(X)"])

      # `mortal(socrates)` is never asserted; it follows from the rule. This is the whole
      # point of doubling a conversation with Prolog rather than a key-value store.
      assert Conversation.query(conv, "mortal(socrates)") == {:ok, true}
      refute Enum.any?(Conversation.kb_snapshot(conv), &(&1.text == "mortal(socrates)."))
    end

    test "the closed-world assumption gives a definite no", %{conv: conv} do
      Conversation.assert(conv, ["human(socrates)", "mortal(X) :- human(X)"])
      assert Conversation.query(conv, "mortal(zeus)") == {:ok, false}
    end

    test "clauses are classified as they are stored", %{conv: conv} do
      Conversation.assert(conv, ["human(socrates)", "mortal(X) :- human(X)", ":- fish(socrates)"])

      assert Enum.map(Conversation.kb_snapshot(conv), & &1.kind) == ["fact", "rule", "constraint"]
    end

    test "known predicates are reported for the next prompt's vocabulary", %{conv: conv} do
      Conversation.assert(conv, ["human(socrates)", "age(socrates, 70)"])
      assert Enum.sort(Conversation.known_predicates(conv)) == ["age/2", "human/1"]
    end
  end

  describe "the runaway-query kill switch, level 1" do
    test "a non-terminating goal is bounded per query", %{conv: conv} do
      Conversation.assert(conv, ["loop(N) :- N1 is N+1, loop(N1)"])
      assert Conversation.query(conv, "loop(0)", 1) == {:error, "time_limit_exceeded"}
    end

    test "and the conversation is still usable afterwards", %{conv: conv} do
      Conversation.assert(conv, ["loop(N) :- N1 is N+1, loop(N1)", "fine(1)"])
      Conversation.query(conv, "loop(0)", 1)
      assert Conversation.query(conv, "fine(1)") == {:ok, true}
    end
  end

  describe "contradiction detection" do
    test "a constraint is not violated until something makes its body provable", %{conv: conv} do
      Conversation.assert(conv, ["whale(willy)", ":- whale(A), fish(A)"])
      assert Conversation.check_constraints(conv) == []
    end

    test "a provable constraint body is a contradiction, with a witness", %{conv: conv} do
      Conversation.assert(conv, ["whale(willy)", ":- whale(A), fish(A)"])

      clauses = Conversation.prepare_clauses(conv, "t1", ["fish(willy)"])
      assert %{added: [_]} = Conversation.commit_clauses(conv, clauses)

      assert [%{witness: %{"A" => "willy"}, constraint: constraint}] =
               Conversation.check_constraints(conv)

      assert constraint.text == ":- whale(A), fish(A)."
    end

    test "an undefined predicate is not a violation", %{conv: conv} do
      # `unknown = fail` is set per engine so a constraint mentioning a predicate nothing has
      # defined yet fails rather than throwing — otherwise every check would look like an
      # error rather than "no violation".
      Conversation.assert(conv, [":- whale(A), fish(A)"])
      assert Conversation.check_constraints(conv) == []
      assert Conversation.query(conv, "nosuch(X)") == {:ok, false}
    end
  end

  describe "clauses that must not reach Prolog" do
    test "a fact carrying a variable is refused and reported", %{conv: conv} do
      # `pet(jane, _)` would make `pet(jane, X)` succeed for every X, silently poisoning
      # every later query about that predicate while looking like an ordinary fact.
      clauses = Conversation.prepare_clauses(conv, "t1", ["pet(jane, _)"])
      assert %{added: [], flagged: [%{reason: reason}]} = Conversation.commit_clauses(conv, clauses)
      assert reason =~ "may not contain variables"

      assert Conversation.query(conv, "pet(jane, anything)") == {:ok, false}
    end

    test "rules and constraints keep their variables", %{conv: conv} do
      clauses =
        Conversation.prepare_clauses(conv, "t1", ["mortal(X) :- human(X)", ":- whale(A), fish(A)"])

      assert %{added: [_, _], flagged: []} = Conversation.commit_clauses(conv, clauses)
    end
  end
end
