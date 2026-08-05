:- encoding(utf8).
% The directive above has to be the very first thing in the file, ahead of even
% this comment: `consult/1` picks an encoding from the OS locale until it sees
% one, and a prelude consulted into an engine started under a non-UTF-8 locale
% (`LC_CTYPE=POSIX`, seen in this very sandbox) would otherwise misread the em
% dashes and curly quotes below as "Illegal multibyte Sequence" -- a warning
% today, since it only corrupts comments, but not something to leave
% load-bearing on the deployment's locale.

% ---------------------------------------------------------------------------
% The "why" meta-interpreter (Sterling & Shapiro, *The Art of Prolog*).
%
% A conversation only ever sees a clause's *answer* — true, false, or bindings —
% never the derivation behind it. That's fine for most goals, but "why is this
% true?" is itself a legitimate question, and Prolog can answer it about its own
% reasoning at least as well as the model sitting on top of it: the interpreter
% that decides whether a goal holds can just as easily record *how* it decided,
% instead of throwing that away the moment it succeeds.
%
% `solve/2` is the textbook "vanilla" meta-circular interpreter —
%
%   solve(true).
%   solve((A,B)) :- solve(A), solve(B).
%   solve(A) :- clause(A,B), solve(B).
%
% — with one addition: a second argument that mirrors the derivation instead
% of discarding it. Each subgoal becomes one of three proof shapes:
%
%   fact(G)              — G matched a fact (a clause whose body is `true`) directly.
%   rule(G, ProofB)       — G matched a rule head; ProofB is how its body was proved.
%   either(Side, ProofG)  — G was one arm of a `;/2` disjunction; Side is `left` or
%                            `right` and ProofG explains the arm that actually fired.
%   builtin(G)            — G is a system predicate (`>/2`, `is/2`, `\+/1`, …); it was
%                            just called, not looked up, because `clause/2` only
%                            sees predicates defined by clauses and raises a
%                            `permission_error` on anything else.
%
% A conjunction's proof (ProofB above, when the body has more than one goal) is
% a **flat list** of its conjuncts' proofs — `[fact(price(widget,150)),
% builtin(150>100)]` — not the nested `(P1, (P2, P3))` shape `,`/2 itself
% builds. `,`/2 is right-associative and arbitrary-length, so a proof shaped
% the same way would make a three-goal body indistinguishable in structure
% from "two goals, the second of which is itself two goals" — a distinction
% about how the *source text* happened to associate, not about the proof.
% `conj_list/2` walks that chain once and flattens it; a single-goal body
% stays a bare proof term rather than a one-element list, since it was never
% a conjunction to begin with.
%
% A disjunction is the opposite shape from a conjunction: exactly one arm
% fires, never both, so there's nothing to flatten — only which arm to name.
% `solve/2`'s `;/2` clause tries the left arm first and, only if that fails,
% the right, exactly like `;/2` itself; the proof it keeps is only ever the
% arm that actually succeeded, tagged `either(left, _)` or `either(right, _)`
% rather than the untried alternative. It stays exactly as non-deterministic
% as plain `;/2` — backtracking into it (`findall/3` over `why/2`, or a second
% `;`-arm of its own) still reaches every solution from the left arm before
% falling through to the right, one `either/2` per solution, not one summary
% covering both.
%
% `why/2` is the entry point: `why(Goal, Proof)` is `solve/2` under the name a
% caller actually wants to ask for — e.g. `?- why(mortal(socrates), Proof)` in
% question mode (`docs/PROTOCOL.md#question-mode`).
%
% Two things this deliberately does not do:
%
%   * Look inside `->/2`. `(Cond -> Then ; Else)` parses as `;(->(Cond,Then),
%     Else)`, so the `;/2` clause below still fires and still reports whether
%     it was the if-then side or `Else` that proved the goal — but the
%     if-then arm itself is a `->/2` term, which is a built-in as far as
%     `solve/2` is concerned, so it becomes one opaque `builtin((Cond->Then))`
%     leaf rather than `Cond` and `Then` explained separately. A plain
%     `(Cond -> Then)` with no `;` gets the same treatment, for the same
%     reason. Distinguishing "committed to `Cond`, then proved `Then`" is a
%     straightforward extension, left out here to keep the rest of the
%     interpreter the textbook one.
%   * Print anything. A textbook "why" shell writes its explanation to the
%     terminal for a person watching a REPL; this one is `consult/1`ed into an
%     engine that only ever answers queries over MQI (`Manifold.Prolog.MQI`),
%     so `why/2` hands back the proof as an ordinary term instead — it travels
%     over the query protocol like any other binding, and the caller (a test,
%     or a client issuing `?- why(...)`) decides how to render it.
%
% The `;/2` and `builtin/1` clauses both have to come *before* `fact/1` and
% `rule/2`: `;/2` is itself a built-in, so `clause((A;B), true)` would raise
% the same `permission_error` `clause(1>2, _)` does (it does not just fail),
% and `predicate_property(Goal, built_in)` is cheap and never throws — not
% even on an undefined predicate — which is what routes a built-in around
% `clause/2` entirely rather than into it. `;/2` has to come before the
% generic `builtin/1` clause too, or `predicate_property((A;B), built_in)`
% would claim the whole disjunction first and `call/1` it as one step,
% exactly the outcome `either/2` exists to avoid.
%
% This runs ahead of `set_prolog_flag(unknown, fail)` (`Manifold.Conversation`
% sets that after consulting the prelude), so every predicate this file uses —
% `clause/2`, `predicate_property/2`, `call/1`, `!/0` — must already be kernel-
% resident rather than autoloaded: anything not yet loaded by the time that
% flag is set can never be autoloaded afterwards
% (`test/smoke/prolog_autoload_test.exs`). All four are.
% ---------------------------------------------------------------------------

solve(true, true) :- !.
solve((A, B), [ProofA | ProofBs]) :- !, solve(A, ProofA), conj_list(B, ProofBs).
solve((A ; B), Proof) :-
    !,
    ( solve(A, ProofA), Proof = either(left, ProofA)
    ; solve(B, ProofB), Proof = either(right, ProofB)
    ).
solve(Goal, builtin(Goal)) :- predicate_property(Goal, built_in), !, call(Goal).
solve(Goal, fact(Goal)) :- clause(Goal, true), !.
solve(Goal, rule(Goal, ProofBody)) :- clause(Goal, Body), solve(Body, ProofBody).

% Flatten a right-nested `,`/2 chain into a list of proofs, one per conjunct,
% instead of recursing through `solve/2`'s own conjunction clause again (which
% would nest one list inside another per extra conjunct rather than flatten).
conj_list((A, B), [ProofA | ProofBs]) :- !, solve(A, ProofA), conj_list(B, ProofBs).
conj_list(Goal, [Proof]) :- solve(Goal, Proof).

why(Goal, Proof) :- solve(Goal, Proof).
