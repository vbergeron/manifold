# ADR 0001: degrade strategy for constrained decoding on external models

Status: **accepted** (decision only — no code lands with this ADR; it unblocks the
external-client work tracked from #9).

Resolves #10. Depends on #9 (`Manifold.Model`), which is already merged: `Manifold.Turn`
and `Manifold.Gate` call `Manifold.Model.completion/2` / `stream/3` (`lib/manifold/turn.ex:41`,
`lib/manifold/gate.ex:34`), not `Manifold.Llama.Client` directly, and the backend is
selected with `config :manifold, model: ...` (`config/config.exs:9`).

## The three call sites, and why they don't get the same answer

| Call site | `lib/manifold/gate.ex:122` `label/1` | `lib/manifold/turn.ex:156` `extract/4` | `lib/manifold/turn.ex:199` `query/4` |
|---|---|---|---|
| Grammar today | `Grammar.gate/0` | `Grammar.prolog/0` | `Grammar.prolog/0` |
| Output shape | one of 3 fixed words, per sentence | free-form Prolog (facts/rules) | free-form Prolog (goals) |
| Existing degrade path | `classify_lexically/1` | none (grammar was assumed to make failure impossible) | none |

The output space is what decides the strategy, not the fact that both go through GBNF
today. A fixed enumeration and an open-ended Prolog term are not the same problem, and
the options in the issue are not equally good fits for both:

- **Gate is a closed vocabulary.** `chitchat | statement | question`, one per sentence.
  Every hosted provider worth targeting (Anthropic tool-use, OpenAI JSON mode /
  structured outputs) can constrain a field to an enum and will *reject or reformat* a
  value outside it before it ever reaches us. That is a real guarantee, not a
  best-effort one — option **B** applies cleanly here because the thing being
  constrained (an enum) is exactly the thing JSON Schema is good at.
- **`extract`/`query` are open-ended Prolog.** Option B's own weakness, named in the
  issue, is fatal here: wrapping the output in a JSON envelope constrains the envelope,
  not the Prolog string inside it. `{"clause": "<anything>"}` validates against any
  schema a provider offers; it buys nothing over asking for Prolog directly. There is no
  provider primitive that expresses "valid GBNF-Prolog," so these two call sites cannot
  get a hard guarantee from an external model, full stop.

## Decision

**Gate → Option B.** `label/1`'s external implementation asks for a structured
response — one enum value per sentence, via tool-use/structured-output — instead of
three-word free text. `label/1`'s existing contract doesn't change: `{:ok, labels}` on a
count match, `:error` (falling back to `classify_lexically/1`, `lib/manifold/gate.ex:91`)
on a mismatch or provider failure, same as the local backend today. Because the provider
enforces the enum itself, this path is **as guaranteed as local GBNF** for this call
site — no new degraded tier is needed for `Gate` specifically, on any backend that
supports structured output. A backend that doesn't support it degrades to
`classify_lexically/1`, exactly like a missing local model does today.

**`extract`/`query` → Option A.** A strong system-prompt instruction ("emit only valid
Prolog clauses, nothing else") plus a bounded validate-and-retry loop, where "valid"
means what it already means in this codebase: `Clause.split/1` finds at least one
balanced clause (`lib/manifold/clause.ex:23`) and, for `extract`, none of them trip
`Clause.rejection/1` (`lib/manifold/clause.ex:129`). No new parser is needed — the
retry loop is a caller wrapped around a validator this codebase already had to write for
truncation and the variable-in-a-fact case. This is genuinely **Option A**, not a
disguised Option B: the JSON-envelope trick was rejected above, so there is nothing
tighter than prompting + retry available for this shape of output on a hosted API.
**This is the new, honestly-degraded third tier** the issue anticipated: *best-effort
external, retry-validated* — weaker than local GBNF, stronger than a single
ungrammared shot, and never silent about which one is active.

Rejected: **Option C as literally stated** (Gate degrades to prompting, `extract`/query
get the JSON envelope) — backwards from the above, for the reasons given per site. The
accepted decision is a hybrid too, just assigned the other way round.

## Where the retry loop lives

Not inside `Manifold.Llama.Client`, and not inside a future
`Manifold.Anthropic.Client`/`Manifold.OpenAI.Client` either: a `Manifold.Model`
implementation (`lib/manifold/model.ex:33`) knows nothing about Prolog, on purpose —
that boundary is the entire point of #9, and it must stay that way so the seam doesn't
grow provider *or* domain logic. `Clause` is the validator, and `Turn`/`Gate` are the
only modules that already import it, so the retry loop belongs in `extract/4` and
`query/4` themselves, conditioned on whether the active backend can guarantee syntax.

That condition needs a way to be asked. Add one capability query the follow-up issue
should implement:

```elixir
@callback constrained?() :: boolean()
```

`Manifold.Llama.Client` returns `true` (GBNF is load-bearing there — see
`priv/grammar/prolog.gbnf` via `Manifold.Grammar.prolog/0`). An external backend
returns `false`. `extract/4`/`query/4` skip the retry loop entirely when `true` (today's
behavior, unchanged, zero cost on the local path) and run it — capped, e.g. one retry,
matching `@max_goals`'s existing spirit of a small fixed bound — when `false`. Exhausting
retries lands in the same place a truncated/empty local generation already does
(`lib/manifold/turn.ex:170-177`), not a new failure shape.

## Surfacing the weakened guarantee

The rule from the issue is explicit: a weakened guarantee "must be visible in the
protocol/UI, not silently absorbed." Two additions, mirroring how the no-model case is
already surfaced (`ready.llama` in `Manifold.ready?/0`, exercised by
`test/integration/no_model_test.exs`):

1. **Handshake.** The `session`/`ready` payload (`docs/PROTOCOL.md`) gains a field —
   e.g. `syntax_guaranteed: bool` — reflecting `Model.impl().constrained?()`. A client
   can then render the same kind of banner it would for a missing model, instead of a
   user discovering the difference only when a malformed clause is silently dropped.
2. **A new typed error code.** `docs/PROTOCOL.md`'s error table (`docs/PROTOCOL.md:178`)
   gains `prolog_retry_exhausted` — "best-effort generation could not be validated after
   retrying" — distinct from `grammar_parse_failed`, whose doc comment ("should be rare
   under GBNF") is specifically a claim about the grammar-guaranteed path and must not
   quietly start meaning something else. Adding a code is backward compatible per the
   protocol's own versioning rule (`docs/PROTOCOL.md:195`).

Both are additive to the existing envelope — no `v` bump.

## The README/CLAUDE.md claim

Today's README states the GBNF guarantee unqualified (`README.md:60`, `README.md:161-162`,
`Manifold.Clause`'s moduledoc: "The GBNF grammar ... already guarantees the model's
output is syntactically valid", `lib/manifold/clause.ex:6`). That sentence is true only
of the local backend and becomes false, as written, the day an external one exists.

Decision: the claim gets a qualifier, not a retraction — manifold's guarantee is real
and worth keeping prominent for the local path. When the external-client issue lands:

- README's architecture section states the guarantee is **conditional on the active
  backend**: guaranteed under `Manifold.Llama.Client` (GBNF), best-effort and
  retry-validated under an external `Manifold.Model` implementation.
- `Manifold.Clause`'s moduledoc gets the same qualifier, since it currently asserts the
  guarantee as a codebase-wide fact rather than a local-backend fact — the reason it
  "never has to validate" stops being true once `constrained?/0` can return `false`.
- `Manifold.Model`'s moduledoc documents `constrained?/0` alongside `completion/2`/
  `stream/3` as part of the seam's contract.

`CLAUDE.md` makes no claim about grammar guarantees today (it documents the test tiers,
not the architecture), so it needs no change from this decision.

## Non-goals of this ADR

No code changes ship with this document. Follow-up work (a new issue, per #10's own
"done" criteria) implements: the first external `Manifold.Model` backend, `constrained?/0`
on both implementations, the retry loop in `Turn`/`Gate`, the `prolog_retry_exhausted`
error code, the `syntax_guaranteed` handshake field, and the README/`Clause` moduledoc
qualifiers above.
