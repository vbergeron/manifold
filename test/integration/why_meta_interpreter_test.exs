defmodule Manifold.Integration.WhyMetaInterpreterTest do
  # Not async, for the same reason as `PreludeTest`: `:prelude_path` is process-global
  # app env, shared with every other test.
  use Manifold.EngineCase, async: false

  @moduletag :capture_log

  # `priv/prelude.pl` is the shipped example prelude: the textbook "why" meta-interpreter
  # (`solve/2`/`why/2`, see the file's own header for the design). This exercises the
  # actual file that ships, consulted the same way any deployment would point
  # `MANIFOLD_PRELUDE` at it — not a copy re-typed into the test.

  setup do
    put_env!(:prelude_path, Application.app_dir(:manifold, "priv/prelude.pl"))
    {_id, conv} = open_conversation!()
    {:ok, conv: conv}
  end

  test "why/2 explains a fact directly", %{conv: conv} do
    Conversation.assert(conv, ["human(socrates)"])

    assert {:ok, {:bindings, [[binding]]}} = Conversation.query(conv, "why(human(socrates), Proof)")

    assert binding == %{
             "functor" => "=",
             "args" => [
               "Proof",
               %{"functor" => "fact", "args" => [%{"functor" => "human", "args" => ["socrates"]}]}
             ]
           }
  end

  test "why/2 walks a rule down to the fact that proves its body", %{conv: conv} do
    Conversation.assert(conv, ["human(socrates)", "mortal(X) :- human(X)"])

    assert {:ok, {:bindings, [[binding]]}} = Conversation.query(conv, "why(mortal(socrates), Proof)")

    assert binding == %{
             "functor" => "=",
             "args" => [
               "Proof",
               %{
                 "functor" => "rule",
                 "args" => [
                   %{"functor" => "mortal", "args" => ["socrates"]},
                   %{"functor" => "fact", "args" => [%{"functor" => "human", "args" => ["socrates"]}]}
                 ]
               }
             ]
           }
  end

  test "why/2 aggregates a conjunction's proof into a flat list, not nested tuples", %{conv: conv} do
    Conversation.assert(conv, [
      "price(widget, 150)",
      "triple(X) :- price(X, P), P > 100, P < 1000"
    ])

    assert {:ok, {:bindings, [[binding]]}} = Conversation.query(conv, "why(triple(widget), Proof)")

    # A three-goal body is one flat list of three proofs — `,`/2 is right-associative,
    # so the naive shape would nest the last two under the first instead.
    assert %{
             "functor" => "=",
             "args" => [
               "Proof",
               %{
                 "functor" => "rule",
                 "args" => [
                   %{"functor" => "triple", "args" => ["widget"]},
                   [
                     %{
                       "functor" => "fact",
                       "args" => [%{"functor" => "price", "args" => ["widget", 150]}]
                     },
                     %{"functor" => "builtin", "args" => [%{"functor" => ">", "args" => [150, 100]}]},
                     %{"functor" => "builtin", "args" => [%{"functor" => "<", "args" => [150, 1000]}]}
                   ]
                 ]
               }
             ]
           } == binding
  end

  test "why/2 tags the arm that actually fired in a disjunction", %{conv: conv} do
    Conversation.assert(conv, [
      "vegetarian(plato)",
      "sentient(X) :- (human(X) ; vegetarian(X))"
    ])

    assert {:ok, {:bindings, [[binding]]}} = Conversation.query(conv, "why(sentient(plato), Proof)")

    # `plato` only satisfies the right arm — the proof says `either(right, _)`, not the
    # raw disjunction `call/1`-ed as one opaque step, and not the untried left arm either.
    assert binding == %{
             "functor" => "=",
             "args" => [
               "Proof",
               %{
                 "functor" => "rule",
                 "args" => [
                   %{"functor" => "sentient", "args" => ["plato"]},
                   %{
                     "functor" => "either",
                     "args" => [
                       "right",
                       %{
                         "functor" => "fact",
                         "args" => [%{"functor" => "vegetarian", "args" => ["plato"]}]
                       }
                     ]
                   }
                 ]
               }
             ]
           }
  end

  test "why/2 backtracks into both arms when both prove the goal", %{conv: conv} do
    Conversation.assert(conv, [
      "human(socrates)",
      "vegetarian(socrates)",
      "sentient(X) :- (human(X) ; vegetarian(X))"
    ])

    assert {:ok, {:bindings, solutions}} = Conversation.query(conv, "why(sentient(socrates), Proof)")

    # One `either/2` per solution — a summary that mentioned both arms in one answer
    # would be exactly the loss of resolution `either/2` exists to avoid.
    proofs =
      Enum.map(solutions, fn [%{"functor" => "=", "args" => ["Proof", proof]}] -> proof end)

    assert Enum.sort(proofs) ==
             Enum.sort([
               %{
                 "functor" => "rule",
                 "args" => [
                   %{"functor" => "sentient", "args" => ["socrates"]},
                   %{
                     "functor" => "either",
                     "args" => [
                       "left",
                       %{
                         "functor" => "fact",
                         "args" => [%{"functor" => "human", "args" => ["socrates"]}]
                       }
                     ]
                   }
                 ]
               },
               %{
                 "functor" => "rule",
                 "args" => [
                   %{"functor" => "sentient", "args" => ["socrates"]},
                   %{
                     "functor" => "either",
                     "args" => [
                       "right",
                       %{
                         "functor" => "fact",
                         "args" => [%{"functor" => "vegetarian", "args" => ["socrates"]}]
                       }
                     ]
                   }
                 ]
               }
             ])
  end

  test "why/2 fails, rather than errors, on a goal that does not hold", %{conv: conv} do
    Conversation.assert(conv, ["human(socrates)"])

    assert Conversation.query(conv, "why(human(zeus), Proof)") == {:ok, false}
  end

  test "why/2 fails on a predicate the KB has never heard of", %{conv: conv} do
    assert Conversation.query(conv, "why(unicorn(pat), Proof)") == {:ok, false}
  end
end
