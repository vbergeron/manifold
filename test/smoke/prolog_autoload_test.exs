defmodule Manifold.Smoke.PrologAutoloadTest do
  use Manifold.EngineCase, async: false

  @moduletag :smoke

  @moduledoc """
  ASSUMPTION — and a **known bug**, documented here rather than fixed: setting
  `unknown = fail` on an engine short-circuits SWI-Prolog's autoloader, so every autoloaded
  library predicate silently returns `false` instead of loading.

  `Manifold.Conversation.init/1` sets the flag so that an integrity constraint mentioning a
  not-yet-defined predicate counts as "no violation" rather than throwing an
  `existence_error`. That part works. The cost is that the whole SWI library becomes
  invisible: `member/2`, `last/2`, `sum_list/2` and `aggregate_all/3` all fail rather than
  erroring, which is indistinguishable from a legitimate negative answer.

  Two consequences worth naming:

    * The list support in `priv/grammar/prolog.gbnf` is **inert**. It was added so the model
      could generate `member(X, [bird, fish, cat])` for generate-and-test, and `member/2` can
      never succeed.
    * Counting solutions in tests has to be done by hand rather than with `aggregate_all/3`.

  The fix is to stop using the blunt global flag and wrap only the constraint check in
  `catch(Goal, error(existence_error(procedure, _), _), fail)`, which confines
  undefined-means-no-violation to the one place that wants it.

  **These assertions describe broken behaviour on purpose.** When someone fixes it they will
  fail, and that is the signal: read this file, then delete it and move the coverage into
  `test/integration`.
  """

  setup do
    {_id, conv} = open_conversation!()
    {:ok, conv: conv}
  end

  test "the autoload flag claims to be on", %{conv: conv} do
    assert {:ok, {:bindings, [[%{"args" => ["A", "true"]}]]}} =
             Conversation.query(conv, "current_prolog_flag(autoload, A)")
  end

  test "unknown = fail is set, which is what breaks autoloading", %{conv: conv} do
    assert {:ok, {:bindings, [[%{"args" => ["U", "fail"]}]]}} =
             Conversation.query(conv, "current_prolog_flag(unknown, U)")
  end

  test "library predicates silently fail instead of loading", %{conv: conv} do
    for goal <- ["member(1, [1,2,3])", "last([1,2,3], 3)", "sum_list([1,2], 3)"] do
      assert Conversation.query(conv, goal) == {:ok, false},
             """
             #{goal} now succeeds — autoloading appears to work.

             If `unknown = fail` has been replaced by a scoped `catch/3` around the
             constraint check, this file has served its purpose: delete it, and move these
             goals into test/integration as positive assertions. Check that the grammar's
             list support is now usable too.
             """
    end
  end

  test "which is why a solution count cannot use aggregate_all/3", %{conv: conv} do
    Conversation.assert(conv, ["p(1)", "p(2)"])

    # The tempting way, which silently answers `false` rather than raising.
    assert Conversation.query(conv, "aggregate_all(count, p(_), 2)") == {:ok, false}

    # The way that works: `findall/3` and `length/2` are real built-ins, not autoloaded.
    assert {:ok, {:bindings, [[_x, %{"args" => ["L", [1, 2]]}]]}} =
             Conversation.query(conv, "findall(X, p(X), L)")
  end

  test "a genuinely undefined predicate also fails rather than erroring", %{conv: conv} do
    # This is the behaviour the flag was set for, and it is worth keeping whatever replaces it:
    # an integrity constraint over a predicate nothing has defined must not throw.
    assert Conversation.query(conv, "definitely_not_defined_anywhere(X)") == {:ok, false}
  end
end
