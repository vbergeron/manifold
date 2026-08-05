defmodule Manifold.Prolog.AuditTreeTest do
  use ExUnit.Case, async: true

  alias Manifold.Prolog.AuditTree

  # No swipl needed — these are the exact JSON shapes MQI hands back for a
  # `why/2` proof (`test/integration/why_meta_interpreter_test.exs` exercises
  # the real engine producing them; this checks only what this module does
  # with the shape once it has one).

  defp fact(g), do: %{"functor" => "fact", "args" => [g]}
  defp builtin(g), do: %{"functor" => "builtin", "args" => [g]}
  defp rule(g, body), do: %{"functor" => "rule", "args" => [g, body]}
  defp either(side, arm), do: %{"functor" => "either", "args" => [side, arm]}
  defp goal(f, args), do: %{"functor" => f, "args" => args}
  defp binding(var, value), do: %{"functor" => "=", "args" => [var, value]}

  describe "proof?/1" do
    test "fact, rule, either and builtin are all proofs" do
      assert AuditTree.proof?(fact(goal("human", ["socrates"])))
      assert AuditTree.proof?(builtin(goal(">", [150, 100])))
      assert AuditTree.proof?(rule(goal("mortal", ["socrates"]), fact(goal("human", ["socrates"]))))
      assert AuditTree.proof?(either("right", fact(goal("vegetarian", ["plato"]))))
    end

    test "a flat list of proofs (a conjunction's body) is a proof" do
      assert AuditTree.proof?([fact(goal("a", [])), builtin(goal(">", [1, 0]))])
    end

    test "an ordinary bound value is not a proof" do
      refute AuditTree.proof?("socrates")
      refute AuditTree.proof?(150)
      refute AuditTree.proof?(goal("human", ["socrates"]))
    end

    test "an empty list is not a proof — nothing to derive" do
      refute AuditTree.proof?([])
    end
  end

  describe "proofs/1" do
    test "finds the proof term bound in a solution, ignoring the query result shapes that aren't" do
      proof = rule(goal("mortal", ["socrates"]), fact(goal("human", ["socrates"])))
      solutions = [[binding("Proof", proof)]]

      assert AuditTree.proofs({:bindings, solutions}) == [proof]
    end

    test "true, false and ordinary bindings contribute nothing" do
      assert AuditTree.proofs(true) == []
      assert AuditTree.proofs(false) == []
      assert AuditTree.proofs({:bindings, [[binding("X", "socrates")]]}) == []
    end

    test "one proof per solution, in order, when backtracking finds several" do
      left = rule(goal("sentient", ["socrates"]), either("left", fact(goal("human", ["socrates"]))))
      right = rule(goal("sentient", ["socrates"]), either("right", fact(goal("vegetarian", ["socrates"]))))
      solutions = [[binding("Proof", left)], [binding("Proof", right)]]

      assert AuditTree.proofs({:bindings, solutions}) == [left, right]
    end
  end

  describe "render/1" do
    test "a fact is a one-line tree: just the goal it proves" do
      assert AuditTree.render(fact(goal("human", ["socrates"]))) == "human(socrates)  [fact]"
    end

    test "a rule draws its body as the single child" do
      proof = rule(goal("mortal", ["socrates"]), fact(goal("human", ["socrates"])))

      assert AuditTree.render(proof) == """
             mortal(socrates)  [rule]
             └─ human(socrates)  [fact]\
             """
    end

    test "a conjunction's body becomes siblings, not nesting" do
      proof =
        rule(goal("triple", ["widget"]), [
          fact(goal("price", ["widget", 150])),
          builtin(goal(">", [150, 100])),
          builtin(goal("<", [150, 1000]))
        ])

      assert AuditTree.render(proof) == """
             triple(widget)  [rule]
             ├─ price(widget, 150)  [fact]
             ├─ 150 > 100  [builtin]
             └─ 150 < 1000  [builtin]\
             """
    end

    test "either names the arm that fired, without a redundant [either] tag" do
      proof = rule(goal("sentient", ["plato"]), either("right", fact(goal("vegetarian", ["plato"]))))

      assert AuditTree.render(proof) == """
             sentient(plato)  [rule]
             └─ either (right)
                └─ vegetarian(plato)  [fact]\
             """
    end

    test "nesting three levels deep keeps the connectors straight" do
      proof =
        rule(goal("a", []), [
          fact(goal("b", [])),
          rule(goal("c", []), builtin(goal("d", [])))
        ])

      assert AuditTree.render(proof) == """
             a  [rule]
             ├─ b  [fact]
             └─ c  [rule]
                └─ d  [builtin]\
             """
    end
  end

  describe "audit/1" do
    test "renders every proof term found, in solution order" do
      proof = rule(goal("mortal", ["socrates"]), fact(goal("human", ["socrates"])))
      solutions = [[binding("Proof", proof)]]

      assert AuditTree.audit({:bindings, solutions}) == [AuditTree.render(proof)]
    end

    test "is empty for a query result with nothing proof-shaped in it" do
      assert AuditTree.audit(true) == []
      assert AuditTree.audit({:bindings, [[binding("X", "socrates")]]}) == []
    end
  end
end
