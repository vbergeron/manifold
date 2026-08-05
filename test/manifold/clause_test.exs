defmodule Manifold.ClauseTest do
  use ExUnit.Case, async: true

  alias Manifold.Clause

  doctest Manifold.Clause

  describe "split/1" do
    test "segments on a period followed by whitespace or end of input" do
      assert Clause.split("human(socrates). mortal(X) :- human(X).") == [
               "human(socrates).",
               "mortal(X) :- human(X)."
             ]
    end

    test "keeps decimals intact, since the separator requires whitespace after the period" do
      assert Clause.split("age(alice, 30.5).") == ["age(alice, 30.5)."]
    end

    test "drops truncated output rather than asserting half a clause" do
      # `n_predict` can cut generation off mid-clause; an unbalanced clause is garbage.
      assert Clause.split("p(a). q(") == ["p(a)."]
      assert Clause.split("foo([a, b).") == []
    end

    test "drops mismatched brackets, which counting alone would accept" do
      # `foo(a]` balances by count. Only a stack notices the kinds do not match.
      assert Clause.split("foo(a].") == []
    end

    test "accepts list arguments" do
      assert Clause.split("pets([bird, fish, cat]).") == ["pets([bird, fish, cat])."]
    end
  end

  describe "normalize/1" do
    test "collapses whitespace and leaves exactly one trailing period" do
      assert Clause.normalize("  human( socrates )  ") == "human( socrates )."
      assert Clause.normalize("human(socrates)..") == "human(socrates)."
      assert Clause.normalize("mortal(X)\n:-\thuman(X).") == "mortal(X) :- human(X)."
    end
  end

  describe "kind/1" do
    test "a headless clause is a constraint, which is how negation is represented" do
      assert Clause.kind(":- whale(A), fish(A).") == :constraint
    end

    test "distinguishes rules from facts by the neck" do
      assert Clause.kind("mortal(X) :- human(X).") == :rule
      assert Clause.kind("human(socrates).") == :fact
    end
  end

  describe "constraint_goal/1" do
    test "yields the goal whose success is a contradiction" do
      assert Clause.constraint_goal(":- whale(A), fish(A).") == "whale(A), fish(A)"
    end

    test "is nil for anything with a head" do
      assert Clause.constraint_goal("human(socrates).") == nil
      assert Clause.constraint_goal("mortal(X) :- human(X).") == nil
    end
  end

  describe "signatures/1" do
    test "reports the head for facts and rules" do
      assert Clause.signatures("human(socrates).") == ["human/1"]
      assert Clause.signatures("mortal(X) :- human(X).") == ["mortal/1"]
    end

    test "reports every top-level body goal for a constraint, which has no head" do
      assert Clause.signatures(":- whale(A), fish(A).") == ["whale/1", "fish/1"]
    end

    test "a bare atom is arity zero" do
      assert Clause.signatures("raining.") == ["raining/0"]
    end

    test "nested compounds do not inflate arity" do
      assert Clause.signatures("f(a, g(b, c)).") == ["f/2"]
    end

    test "list arguments do not inflate arity" do
      # The regression this guards: counting commas without tracking brackets read
      # `member(X, [a, b])` as `member/3`, silently corrupting the known-predicate list
      # that every subsequent prompt is built from.
      assert Clause.signatures("member(X, [bird, fish, cat]).") == ["member/2"]
      assert Clause.signatures("p([a, b, c]).") == ["p/1"]
      assert Clause.signatures("q([H|T], X).") == ["q/2"]
    end

    test "sees through the negation operator to the goal it wraps" do
      # Without this the whole term fails to parse and the goal reports *no* predicates,
      # which would let it slip past any check made against the KB's known ones.
      assert Clause.signatures("\\+ flies(tweety)") == ["flies/1"]
      assert Clause.signatures(":- \\+ p(x), q(y)") == ["p/1", "q/1"]
    end
  end

  describe "variables/1" do
    test "finds named variables and the anonymous one" do
      assert Clause.variables("pet(jane, _).") == ["_"]
      assert Clause.variables("f(A, B, A).") == ["A", "B"]
    end

    test "does not mistake an underscore inside a name for a variable" do
      # `has_beak` and `pet1` are atoms. Only an upper-case letter or underscore *starting*
      # a token is a variable.
      assert Clause.variables("has_beak(bird).") == []
      assert Clause.variables("pet1(neither).") == []
    end
  end

  describe "rejection/1" do
    test "refuses a fact carrying a variable" do
      # `pet(jane, _)` does not mean "Jane has some pet" — it makes `pet(jane, X)` succeed
      # for *every* X, so one such clause renders every later query about that predicate
      # meaningless while still looking like an ordinary fact.
      assert Clause.rejection("pet(jane, _).") =~ "may not contain variables"
      assert Clause.rejection("pet(kelly, Pet).") =~ "Pet"
    end

    test "allows ground facts" do
      assert Clause.rejection("human(socrates).") == nil
      assert Clause.rejection("age(carol, 25).") == nil
    end

    test "allows rules and constraints, which are variable-bearing by nature" do
      # There the variable is bound by the body, which is the entire point.
      assert Clause.rejection("mortal(X) :- human(X).") == nil
      assert Clause.rejection(":- whale(A), fish(A).") == nil
    end
  end

  describe "body/1" do
    test "strips the trailing period that assertz and run do not want" do
      assert Clause.body("human(socrates).") == "human(socrates)"
      assert Clause.body("  human(socrates).  ") == "human(socrates)"
    end
  end
end
