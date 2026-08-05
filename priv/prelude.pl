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
%   fact(G)          — G matched a fact (a clause whose body is `true`) directly.
%   rule(G, ProofB)   — G matched a rule head; ProofB is how its body was proved.
%   builtin(G)        — G is a system predicate (`>/2`, `is/2`, `\+/1`, …); it was
%                        just called, not looked up, because `clause/2` only
%                        sees predicates defined by clauses and raises a
%                        `permission_error` on anything else.
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
% `why/2` is the entry point: `why(Goal, Proof)` is `solve/2` under the name a
% caller actually wants to ask for — e.g. `?- why(mortal(socrates), Proof)` in
% question mode (`docs/PROTOCOL.md#question-mode`).
%
% Two things this deliberately does not do:
%
%   * Handle `;/2` or `->/2`. The vanilla interpreter only ever knew about
%     conjunction; if a rule body needs disjunction, that disjunction is a
%     built-in as far as `solve/2` is concerned and gets `call/1`-ed as one
%     opaque step rather than explained subgoal by subgoal. Widening it to
%     explain `;/2` and `->/2` piecemeal is a straightforward extension, left
%     out here to keep the base interpreter the textbook one.
%   * Print anything. A textbook "why" shell writes its explanation to the
%     terminal for a person watching a REPL; this one is `consult/1`ed into an
%     engine that only ever answers queries over MQI (`Manifold.Prolog.MQI`),
%     so `why/2` hands back the proof as an ordinary term instead — it travels
%     over the query protocol like any other binding, and the caller (a test,
%     or a client issuing `?- why(...)`) decides how to render it.
%
% The `builtin/1` clause has to come *before* `fact/1` and `rule/2`: `clause/2`
% raises a `permission_error` on a genuine built-in (`clause(1>2, _)` throws,
% it does not just fail), so that clause must never be reached for one.
% `predicate_property(Goal, built_in)` is cheap and never throws — not even on
% an undefined predicate — which is what routes a built-in around `clause/2`
% entirely rather than into it.
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
solve(Goal, builtin(Goal)) :- predicate_property(Goal, built_in), !, call(Goal).
solve(Goal, fact(Goal)) :- clause(Goal, true), !.
solve(Goal, rule(Goal, ProofBody)) :- clause(Goal, Body), solve(Body, ProofBody).

% Flatten a right-nested `,`/2 chain into a list of proofs, one per conjunct,
% instead of recursing through `solve/2`'s own conjunction clause again (which
% would nest one list inside another per extra conjunct rather than flatten).
conj_list((A, B), [ProofA | ProofBs]) :- !, solve(A, ProofA), conj_list(B, ProofBs).
conj_list(Goal, [Proof]) :- solve(Goal, Proof).

why(Goal, Proof) :- solve(Goal, Proof).
