# Proposal: multi-pass autonomous querying

**Status:** proposed, not implemented. This document specifies the change; it
does not ship it.

## The one-pass limit today

`Manifold.Turn.query/4` makes exactly one model call
(`Manifold.Prompt.goals/2`) per turn, gets back up to `@max_goals` (3) Prolog
goals in a single generation, and runs each of them once against the KB —
blind to what the others returned. Nothing downstream of that generation can
react to a result:

```elixir
# lib/manifold/turn.ex, today
generate(Prompt.goals(text, known), @goals_opts, turn, subscriber)
|> Clause.split()
|> Enum.take(@max_goals)
|> Enum.map(&run_goal(conv, turn, &1, known, subscriber))
```

That is a real ceiling, not just a small one. Anything that needs the *result*
of one goal to phrase the next is unreachable in one pass:

- **Multi-hop lookups.** "Who is Bob's paternal grandfather?" over
  `parent/2` needs `parent(bob, X)` to bind `X`, then a second, *literal* goal
  built from that binding — `parent(alice, Y)` — because Prolog variables
  don't survive across separate `MQI.run/3` calls the way they would within
  one clause body. One generation cannot know `X = alice` before it has run.
- **Self-correction.** If the model guesses a predicate that turns out not to
  be in `known_predicates` (`run_goal/5`'s `:unanswered` path), there is no
  second chance in the same turn — that evidence is simply absent from
  `respond`.
- **Adaptive stopping.** Three goals run whether the first one already
  answered the question or none of them are relevant; the budget is fixed by
  the prompt shots, not by how much evidence has actually accumulated.

## What is *not* changing

The sealed loop's ordering rules (`Manifold.Turn`, README "The turn loop")
stay exactly as they are. This proposal touches only the inside of the
**query** phase — the box after assert/check, before respond:

1. **Gate once, up front** — unchanged, still one call.
2. **Assert before query** — unchanged. Multi-pass querying still starts only
   after this turn's clauses are committed; `known_predicates` is fixed for
   the whole query phase (see "Non-goals" below).
3. **Contradiction overrides the gate** — unchanged; a contradiction still
   skips the query phase entirely, multi-pass included.

Question mode is untouched: it runs one goal verbatim, by design, with no
model in the loop before `respond`. This proposal is about the *gated*
path's query phase only.

## Design: a bounded reason → act → observe loop

Replace "generate 3 goals at once" with "generate one goal, run it, show the
model the result, let it decide whether to ask again or stop" — a ReAct-style
loop, capped hard enough that it is still a bounded, testable state machine
rather than an open-ended agent.

```
round 1: ask(history=[])              -> "parent(bob, X)."
         run -> X = alice             -> history: [{parent(bob, X)., "X = alice"}]
round 2: ask(history)                 -> "parent(alice, Y)."
         run -> Y = carol             -> history: [..., {parent(alice, Y)., "Y = carol"}]
round 3: ask(history)                 -> "DONE."
         -> stop, evidence = [X=alice, Y=carol] answers already collected
```

### New prompt: `Prompt.next_goal/3`

One more prompt alongside `gate/1`, `extract/2`, `goals/2`, `respond/1`.
Same shape as `goals/2` (ChatML, few-shot, paired with a grammar) but it also
carries the round history, and it teaches the model the stopping sentinel:

```elixir
@spec next_goal(String.t(), [String.t()], [{String.t(), String.t()}]) :: String.t()
def next_goal(question, known_predicates, history)
```

Shots need to cover the three cases the loop actually hits:

- *Single-hop, done in one round* — the shot answers `DONE.` in round 2 once
  round 1 already resolved the question.
- *Multi-hop* — round 1's binding is threaded, verbatim, into round 2's goal
  text, exactly as `history` renders it.
- *Self-correction* — round 1 comes back "no matching predicate", round 2
  asks something answerable instead of repeating it.

`history` renders the same way `Prompt.respond/1`'s evidence lines already
do (`answer_text/1` reused, not reinvented) — one line per prior round:
`"parent(bob, X). -> X = alice"`.

### New grammar: `priv/grammar/next_goal.gbnf`

A trimmed variant of `prolog.gbnf`'s term grammar: the sentinel or exactly
one goal, never a clause list, never a rule or constraint (a query round
asks something, it doesn't add a integrity constraint):

```gbnf
root        ::= "DONE." | goal "." ws
goal        ::= negation | term
negation    ::= "\\+" ws term
term        ::= compound | atom
compound    ::= atom "(" ws args ws ")"
args        ::= arg (ws "," ws arg)*
arg         ::= variable | number | list | term
list        ::= "[" ws (listitems ws)? "]"
listitems   ::= arg (ws "," ws arg)* (ws "|" ws variable)?
atom        ::= [a-z] [a-zA-Z0-9_]*
variable    ::= [A-Z_] [a-zA-Z0-9_]*
number      ::= "-"? [0-9]+ ("." [0-9]+)?
ws          ::= [ \t\n]*
```

Open question worth a real decision, not a default: should a round be
allowed to emit a *conjunction* (`goal (, goal)*`, matching `body` in
`prolog.gbnf`) instead of exactly one goal? Multi-hop doesn't need it — that
is precisely what the extra round is for — but it would let one round answer
"is X both a Y and a Z?" without spending two. I'd ship the single-goal
version first: it keeps every round's evidence line attributable to exactly
one goal, which is what makes the history render simple and the loop easy to
reason about.

### The control flow: a pure loop, effects injected

Round bookkeeping (parse the model's output, dedupe, count rounds, decide
when to stop) should not depend on an engine or a model to test, per
`CLAUDE.md`'s tiering rule — so it's worth pulling out of `Turn` into its own
module that takes `ask` and `run_goal` as plain functions:

```elixir
defmodule Manifold.Turn.QueryLoop do
  @moduledoc """
  The multi-pass query phase's control flow, isolated from its effects.
  `ask` and `run_goal` are injected so this is testable with no swipl and no
  model — see test/manifold/turn/query_loop_test.exs.
  """

  @max_rounds 4

  @spec parse_step(String.t()) :: :done | {:goal, String.t()}
  def parse_step(output) do
    case String.trim(output) do
      done when done in ["DONE.", "DONE"] -> :done
      other ->
        case Manifold.Clause.split(other) do
          [clause | _] -> {:goal, Manifold.Clause.body(clause)}
          # Truncated or unparseable output under a grammar that guarantees
          # syntax should not happen — but a hung loop is a worse failure
          # than one that stops one round early, so treat it as DONE.
          [] -> :done
        end
    end
  end

  @spec run(([{String.t(), String.t()}] -> {:ok, String.t()} | {:error, term()}),
            (String.t() -> {:answer, map()} | {:unanswered, map()} | :none),
            keyword()) :: {[map()], [map()]}
  def run(ask, run_goal, opts \\ []) do
    loop(ask, run_goal, _history = [], _seen = MapSet.new(), [], [], 1, Keyword.get(opts, :max_rounds, @max_rounds))
  end

  defp loop(_ask, _run_goal, _h, _seen, answers, unanswered, round, max) when round > max,
    do: {Enum.reverse(answers), Enum.reverse(unanswered)}

  defp loop(ask, run_goal, history, seen, answers, unanswered, round, max) do
    with {:ok, output} <- ask.(history),
         {:goal, goal} <- parse_step(output),
         norm = Manifold.Clause.normalize(goal),
         false <- MapSet.member?(seen, norm) do
      case run_goal.(goal) do
        {:answer, fields} ->
          loop(ask, run_goal, history ++ [{goal, describe(fields.answer)}], MapSet.put(seen, norm),
               [fields | answers], unanswered, round + 1, max)

        {:unanswered, info} ->
          loop(ask, run_goal, history ++ [{goal, "no matching predicate"}], MapSet.put(seen, norm),
               answers, [info | unanswered], round + 1, max)

        :none ->
          {Enum.reverse(answers), Enum.reverse(unanswered)}
      end
    else
      # :done, a repeated goal (true — model is stuck, not exploring), or a
      # generation error all mean the same thing here: stop with what we have.
      _ -> {Enum.reverse(answers), Enum.reverse(unanswered)}
    end
  end
end
```

`Manifold.Turn.query/4` shrinks to wiring `Conversation.query/3` and
`Client.completion/2` into those two callbacks:

```elixir
defp query(conv, turn, text, subscriber) do
  case Conversation.known_predicates(conv) do
    [] ->
      {[], [%{goal: nil, missing: []}]}

    known ->
      ask = fn history -> generate(Prompt.next_goal(text, known, history), @goals_opts, turn, subscriber) end
      run_goal = fn goal -> run_one_goal(conv, turn, goal, known, subscriber) end
      QueryLoop.run(ask, run_goal)
  end
end
```

`run_one_goal/5` is today's `run_goal/5` body, unchanged (unknown-predicate
check, `Conversation.query/3`, timeout/error handling, `message{kind:query}`
emission) — it just becomes the injected effect instead of being mapped over
a fixed list.

### Bounds — three independent ones, not one

- **Round cap**, `@max_rounds` (proposed: 4 — one more than today's flat 3,
  since most turns will now stop in 1–2 rounds and the ones that need all 4
  are exactly the multi-hop cases this exists for).
- **Repeat detection.** The same normalized goal appearing twice means the
  model is stuck, not exploring — stop rather than spend the rest of the
  round budget re-asking it.
- **Per-goal timeout**, `@query_timeout_s` — already exists, unchanged, and
  still the thing that bounds a single runaway goal.

Wall-clock total is *not* separately capped: round cap × (one short
generation + one bounded query) is already a small, fixed number of
round-trips, so a fourth timer would be redundant bookkeeping for no new
guarantee.

### Cancellation

Unchanged. `cancel_turn` kills the whole `Manifold.Turn` process
(`Conversation.handle_call(:cancel_turn, ...)`); it doesn't know or care
whether it's mid-round-1 or round-4 of the query loop, same as it doesn't
know today whether it's mid-`respond` stream. Nothing here needs a new kill
path.

### Protocol — no version bump

`turn_phase{phase:"query"}` is already documented as "activity indicator"
(`docs/PROTOCOL.md`); emitting it once per round instead of once per turn is
a frequency change, not a shape change, and a client that ignores repeats
today keeps working unmodified. Each round's executed goal still produces
exactly one `message{kind:query}`, identical in shape to what one round of
today's flat 3-goal batch produces — so the UI's query panel, unmodified,
now reads as a visible chain of reasoning instead of an unordered batch of
three, which is a strict readability improvement for free.

One optional addition, non-breaking the same way `gate_result` is
(`docs/PROTOCOL.md` §Server events): a `query_round` telemetry event —
`{round, goal | null}` — emitted alongside each `turn_phase{query}`, so the
UI *could* eventually show "step 2 of up to 4" instead of an opaque spinner.
Not required to ship the feature; easy to add later without another version
bump, so I'd leave it out of v1.

### Non-goals (explicitly out of scope here)

- **Mid-loop assertion.** The model cannot `assertz` a derived fact between
  rounds in this proposal — `known_predicates` is computed once, before the
  loop starts, and stays fixed. Letting a query round add clauses would
  reopen the "assert before query" ordering invariant *inside* a phase that
  currently has none, and needs its own design (in particular: does a
  derived fact get persisted and shown on the left panel, or is it
  scratch state for this turn only?). Worth a follow-up, not bundled here.
- **Cross-turn memory of the reasoning chain.** Only the final `answers` /
  `unanswered` reach `respond` and the transcript, same as today — the
  intermediate rounds are not retained as anything richer than the
  `message{kind:query}` entries already in the transcript.
- **Retry/backoff on a single goal's timeout.** A round that times out still
  just becomes an `error{prolog_timeout}` and the loop moves on, same
  semantics as today's `run_goal/5`.

## Testing plan (per `CLAUDE.md`'s tiers)

- **`test/manifold/turn/query_loop_test.exs`** (pure, no `:swipl` tag): feed
  `QueryLoop.run/3` canned `ask`/`run_goal` functions and assert on the
  returned `{answers, unanswered}` plus call counts —
  - stops on `DONE.` before the round cap;
  - stops at the round cap when the model never emits `DONE.`;
  - stops early on a repeated goal;
  - `parse_step/1` handles `"DONE."`, a well-formed goal, and unparseable
    input (never crashes — grammar guarantees syntax in production, but the
    parser must not assume it).
- **`test/manifold/prompt_test.exs`**, extended: `next_goal/3` — the
  question, known predicates, and each history line all appear in the
  built prompt (property assertions, never exact wording, per
  `CLAUDE.md`).
- **`test/integration/query_loop_test.exs`** (`Manifold.EngineCase`, real
  `swipl`, canned `ask` — the hermetic test config has no model, so this is
  the same pattern `Gate`/`Turn` tests already have to use): assert two or
  more chained facts, drive `Manifold.Turn.QueryLoop.run/3` with a scripted
  `ask` that returns a goal referencing the *previous* round's real binding,
  and confirm the second goal actually resolves against the live KB —  the
  one thing the pure test above cannot prove, because it never touches
  Prolog.
- **No new smoke test.** Nothing here is a new assumption about SWI-Prolog,
  MQI, or OS process cost — it's a new correctness behaviour on top of
  facilities the existing smoke tests already cover.

## Rollout

Land `QueryLoop` and `Prompt.next_goal/3` first, unit-tested in isolation
with `@max_rounds` and both grammars in place, *before* wiring
`Manifold.Turn.query/4` to it — same incremental order the codebase already
uses (grammar → prompt → wiring, see how `Gate` and question mode both
landed). No feature flag needed: replacing `query/4`'s body is a drop-in
swap on the same public shape (`{answers, unanswered}`), so there's no
in-between state to gate behind a config value — either `Turn` calls the old
flat batch or the new loop, and the switch is one commit.
