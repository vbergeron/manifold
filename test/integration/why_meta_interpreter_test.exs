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

  test "why/2 calls a built-in as one opaque step instead of erroring on it", %{conv: conv} do
    Conversation.assert(conv, ["price(widget, 150)", "discount(X) :- price(X, P), P > 100"])

    assert {:ok, {:bindings, [[binding]]}} = Conversation.query(conv, "why(discount(widget), Proof)")

    assert %{
             "functor" => "=",
             "args" => [
               "Proof",
               %{
                 "functor" => "rule",
                 "args" => [
                   %{"functor" => "discount", "args" => ["widget"]},
                   %{
                     "functor" => ",",
                     "args" => [
                       %{
                         "functor" => "fact",
                         "args" => [%{"functor" => "price", "args" => ["widget", 150]}]
                       },
                       %{"functor" => "builtin", "args" => [%{"functor" => ">", "args" => [150, 100]}]}
                     ]
                   }
                 ]
               }
             ]
           } == binding
  end

  test "why/2 fails, rather than errors, on a goal that does not hold", %{conv: conv} do
    Conversation.assert(conv, ["human(socrates)"])

    assert Conversation.query(conv, "why(human(zeus), Proof)") == {:ok, false}
  end

  test "why/2 fails on a predicate the KB has never heard of", %{conv: conv} do
    assert Conversation.query(conv, "why(unicorn(pat), Proof)") == {:ok, false}
  end
end
