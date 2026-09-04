# Manifold

A conversational AI whose every conversation is **doubled** by a live Prolog
session. Natural-language dialogue on one side; a persistent, inspectable Prolog
knowledge base on the other. Facts and rules distilled from the conversation are
`assert`ed into the KB, and the model reasons by *querying* it — deterministic
inference, persistent symbolic state, and contradiction/consistency checking
that a pure-LLM chat cannot give reliably.

## Architecture

Manifold is an Elixir/OTP application. The language model is **one shared** sidecar
OS process; Prolog is **one OS process per conversation**, owned by that
conversation:

```
Manifold.Supervisor                (one_for_one)
├── Manifold.Llama.Server           llama.cpp server — shared, one model in memory
├── Manifold.Conversation.Registry  conversation_id -> pid, for reconnects
├── Manifold.Conversation.Supervisor (DynamicSupervisor, max_children)
│   └── Manifold.Conversation …      one process per conversation:
│       │                            NL transcript + its own swipl OS process
│       ├── swipl (via Port)         Manifold.Prolog.Engine — a private KB
│       └── Manifold.Turn            the turn loop, spawned + monitored per turn
└── Bandit                          HTTP/WebSocket endpoint (Manifold.Web.Router)
```

**Why an engine per conversation, not a shared one.** MQI gives each *connection* its
own thread but **not** its own database: a plain `assertz/1` writes to the
process-global clause store, so with a shared server every conversation's knowledge
base silently merges into every other's, and clauses outlive the connection that made
them. That is measured, not theorised. Per-predicate `thread_local` declarations can
paper over it, but only for clauses asserted through the one code path that remembers
to declare — and a predicate asserted before being declared can never be declared
afterwards. An OS process needs no such discipline. It costs ~90 ms to boot and
~5.3 MB (PSS).

Why Elixir: the design is per-conversation, long-lived, stateful, isolated processes —
OTP's home turf. And the runaway-query escape hatch is real rather than nominal. A
non-terminating goal is bounded per query (MQI timeout), bounded again server-side, and
worst case the engine is **SIGKILLed** — which is now *non-destructive*: that
conversation rehydrates from its own log, losing only the in-flight query, and no other
conversation is touched. With a shared server the same move would have destroyed every
conversation's knowledge base, so this is the argument that only became true once each
conversation owned its engine.

Ownership, not supervision, is what guarantees the engine cannot outlive its
conversation: the conversation holds the `Port`, so when it exits — for *any* reason,
including `:kill` — the port closes and the sh guardian reaps swipl, with no reliance on
`terminate/2` running.

### Key modules

| Module | Role |
|--------|------|
| `Manifold.Application`  | Supervision tree (the model sidecar, conversations, and the endpoint). |
| `Manifold.OsProcess`    | Owns an OS process via a `Port`; a sh guardian kills the child when the owning process dies or on SIGTERM, so nothing is ever orphaned. |
| `Manifold.Llama.Server` | Supervised `llama-server`; polls `/health`; parks in `:no_model` if no GGUF is present. |
| `Manifold.Model`        | The backend seam: a behaviour (`completion/2`, `stream/3`) that `Manifold.Turn` and `Manifold.Gate` call through, resolved from `config :manifold, :model`. Swapping the configured module is the whole integration point for a non-local backend. |
| `Manifold.Llama.Client` | The default `Manifold.Model` backend, talking HTTP to `llama.cpp`; `:grammar` option sends a **GBNF** string for constrained decoding; `stream/3` for token-by-token. |
| `Manifold.Prolog.Engine`| One `swipl` MQI server per conversation, owned by it. MQI picks the port and password and reports them on stdout. |
| `Manifold.Prolog.MQI`   | MQI wire protocol (length-prefixed frames, JSON answers); separates transport failure from a Prolog exception. |
| `Manifold.Prolog.Answer`| Decodes MQI answers into `true` / `false` / bindings, and picks a witness. |
| `Manifold.Conversation` | The "doubling" unit: typed transcript + its own engine, which it owns. Single source of truth for both UI panels. Evicts itself when idle; rehydrates from its log on next open. |
| `Manifold.Turn`         | The turn loop (below), run in its own monitored process so cancel is a kill. |
| `Manifold.Gate`         | The one cheap classification: each sentence labelled `chitchat`/`statement`/`question` by the model under a grammar, yielding `{new_facts?, needs_query?}` + the sentence split. Falls back to a lexical pass with no model. |
| `Manifold.Prompt`       | The four prompts: `gate/1`, `extract/2`, `goals/2`, `respond/1`. |
| `Manifold.Clause`       | Prolog source as data: normalize, classify `fact`/`rule`/`constraint`, split, signatures. Also refuses the one unsound shape the grammar can't exclude — a fact carrying a variable, which would hold for every term. |
| `Manifold.Grammar`      | The GBNF grammars (`priv/grammar/{prolog,gate}.gbnf`), embedded at compile time. |
| `Manifold.Event`        | Builds and emits the protocol envelope to a subscriber. |
| `Manifold.Web.Router`   | The whole HTTP surface: `GET /socket` (upgrade), `GET /health`, and the built UI (`GET /` plus its hashed assets from `priv/static`). |
| `Manifold.Web.Socket`   | The `WebSock` handler: framing, `seq`, keepalive. One socket ⇄ one conversation. |

The wire protocol between server and UI is specified in `docs/PROTOCOL.md`; the
frontend that implements it lives in `ui/` (see `ui/README.md`).

## Toolchain (via mise)

`mise.toml` pins the toolchain. `erlang`, `elixir`, and `llama.cpp` are installed
by mise; **SWI-Prolog uses the system `swipl`** (the asdf plugin builds from
source and needs dev libs that aren't present; system 9.2.8 is identical).

```sh
mise install          # erlang 27, elixir 1.18 (otp-27), llama.cpp
mise exec -- mix deps.get
mise exec -- mix compile
```

## Get a model

The LLM server needs a GGUF model. Drop one at `models/model.gguf` (or point
`MANIFOLD_MODEL` at it). Without a model the app still boots — the Prolog half
is fully functional; the llama server just parks in `:no_model`.

## Run it

Build the UI once, then boot the app — one OS process serves the interface and
the protocol, on `:4000` (override with `MANIFOLD_WEB_PORT`):

```sh
cd ui && mise exec -- npm install && mise exec -- npm run build && cd ..
mise exec -- iex -S mix
```

Open <http://127.0.0.1:4000>. `npm run build` writes the bundle to `priv/static`,
which `Manifold.Web.Router` serves; the same port answers `ws://…/socket`, so
there is no CORS and nothing to configure. Without that build the app still runs
fine — `/` just replies `503` telling you which command to run.

For frontend work you want Vite's dev server instead, on `:5173`, talking to the
same backend:

```sh
cd ui && mise exec -- npm run dev
```

And the UI runs with no backend at all: `http://localhost:5173/?mock=1` drives it
from a scripted fake event feed. See `ui/README.md`.

### Shortcut: mise tasks

The commands above are also wired up as `mise` tasks (`mise tasks` lists them):

```sh
mise run setup      # mix deps.get + npm install
mise run ui:build   # one-shot UI build into priv/static
mise run server     # iex -S mix — boots every service Manifold owns (alias: start)
mise run ui:dev     # Vite dev server on :5173, for frontend work
mise run dev        # backend (non-interactive) + ui:dev together, Ctrl-C stops both
```

## Run the smoke tests

`scripts/smoke.exs` boots the app and drives a doubled conversation against the
real MQI server:

```sh
mise exec -- mix run scripts/smoke.exs
```

Expected highlights:

```
mortal(socrates)?: {:ok, true}     # derived via mortal(X) :- human(X)
mortal(zeus)?:     {:ok, false}
infinite loop, 1s cap: {:error, "time_limit_exceeded"}   # the kill switch
```

`scripts/ws_smoke.exs` checks the web half: the turn loop's event sequence, the
contradiction path, then the real protocol over a real WebSocket against the
endpoint this very app is serving. `scripts/prompt_eval.exs` is the prompt
brittleness harness (a battery of inputs through `extract` under the grammar).

## Using it from IEx

```elixir
{:ok, c} = Manifold.start_conversation()
Manifold.assert(c, ["human(socrates)", "mortal(X) :- human(X)"])
Manifold.query(c, "mortal(socrates)")   #=> {:ok, true}

# GBNF-constrained generation (needs a model):
Manifold.Llama.Client.completion("Facts as Prolog:\n", grammar: Manifold.Grammar.prolog())
```

## The turn loop (committed spec)

Each user message runs through **one gate call, then dependency-ordered
execution**. The gate is a single cheap classification; the grammar only
constrains *how* the model generates, never *whether* it generates.

```
user message
     │
     ▼
[GATE]  one grammar-constrained call → {new_facts?: bool, needs_query?: bool}
     │   (labels each sentence: chitchat / statement / question)
     │
     ├─ if new_facts:  extract clauses under the grammar (facts, rules, or
     │                 `:- Body` integrity constraints) → assert → run every
     │                 integrity constraint; if any body is provable, flag a
     │                 contradiction  (undefined predicate = no violation)
     │                                    │
     ▼                                    ▼
     ├─ if needs_query: generate goals under the grammar (model sees the
     │                  fresh KB) → run with a timeout
     │
     ▼
[RESPOND]  free-form NL reply grounded in the query answers (no grammar)
```

**Negation is represented as integrity constraints.** A negative statement
("X is not a Y", "Tweety doesn't fly") becomes a headless clause `:- Body.`
meaning *"this must never be derivable"* (`:- whale(A), fish(A).`,
`:- flies(tweety).`). This unifies negation with contradiction detection: the
consistency-check simply runs the constraints, and a provable body is a
contradiction. (The grammar allows `:- Body.`; see `priv/grammar/prolog.gbnf`.)

Rules that make this correct:

1. **Gate once, up front.** Both booleans come from a single call that labels each
   sentence `chitchat` | `statement` | `question`, constrained by
   `Manifold.Grammar.gate/0` so the output is three words and nothing else. It has
   to be the model: the distinction is semantic, and the two hard cases are
   lexically indistinguishable from their opposites — *"Use the clues below to find
   out which pet each person owns"* is a query with no question mark, and *"Do you
   like cats?"* is textbook interrogative but must never reach the KB. A word list
   cannot separate those without also breaking `is`/`are`/`does`, which open
   questions and sit mid-sentence in half of all declaratives. `Manifold.Gate` keeps
   a lexical pass as the degraded path for when no model is loaded.

   The four outcomes are chitchat / pure statement / pure question / mixed.
   Abstention ("no facts", "no queries") is a first-class, normal result — which is
   *why the grammar can stay strict* (`clause+`): it is only ever invoked once the
   gate has committed to producing clauses.
2. **Assert before query.** A message often states facts *and* asks about them
   ("Socrates is human. Is he mortal?"). Query goals are generated only *after*
   assertion, so they see the updated KB — a hard read-after-write dependency;
   never parallelise these.
3. **Contradiction is an override.** The gate decides `needs_query?` before
   assertion runs, so it can't foresee a contradiction flagged in the
   consistency-check. If one fires, it *overrides* the gate and forces a
   response path (e.g. "that conflicts with what you told me earlier") rather
   than triggering a second gate call.

This spec is implemented by `Manifold.Turn` (driven via
`Manifold.Conversation.run_turn/4`), which emits each phase as a protocol event.

**Question mode** bypasses the whole loop above. A message whose first
non-whitespace character is `?` (`Manifold.Clause.question?/1`) is not
gated, extracted, or asserted — the rest of the text is run **verbatim** as
a Prolog goal against the KB (`?- ` is accepted too, mirroring `swipl`'s own
prompt). The answer becomes the evidence block, so `[RESPOND]` still gets to
react to it in prose; only the model-driven routing in between is skipped.
It exists for the case the gate can't promise: a query whose syntax and
timing you control directly, rather than one an LLM decided to run.

## Status / next steps

Working end to end: supervision of both sidecars, no-orphan shutdown, MQI
assert/query, inference, per-query timeout kill switch, GBNF grammar plumbing,
the turn loop above, the consistency check (`Conversation.check_constraints/2`,
constraints run with undefined-predicate = fail), the v1 WebSocket protocol
(`docs/PROTOCOL.md`) over Bandit, and the two-panel React UI in `ui/`.

Prompt (`Manifold.Prompt.extract/2`) is iterated and robust across fact shapes
(unary, binary relations, attributes, universal rules, negation-as-constraint)
and reuses existing KB predicates to avoid vocabulary drift. Known weak spot:
complex restrictive quantifiers ("every X who P did Q") are model-inconsistent
at 3B.

Recently added:

- **Question mode.** A message starting with `?` (or `?-`) is run verbatim as a
  Prolog goal — no gate, extraction or assertion — and the answer is fed back
  to `respond` so the model can react to it. See "The turn loop" above and
  `docs/PROTOCOL.md#question-mode`.
- **KB persistence per conversation.** `Manifold.Store.Log` is a pluggable
  append-only ETF log adapter; conversations rehydrate from it on reconnect.
  `Manifold.Store.None` (the default in tests) keeps runs hermetic. Pointed at a
  directory via `MANIFOLD_DATA_DIR`.
- **Prelude file.** Point `MANIFOLD_PRELUDE` at a `.pl` file and it is `consult/1`ed
  into every conversation's own engine at startup, before replay — background rules
  and facts (e.g. `mortal(X) :- human(X).`) available from the first turn, without
  re-asserting them by hand or re-teaching them to the model in every conversation.
  Unset by default. A prelude that fails to load (missing file, a directive that
  errors) fails that conversation's startup rather than silently running without it.

Decided, not yet implemented:

- **External-model degrade strategy.** GBNF-constrained decoding is a local-only
  guarantee — no hosted API exposes arbitrary GBNF. `docs/adr/0001-external-model-decoding-strategy.md`
  settles what each of the three grammar-constrained call sites (`Gate.label/1`,
  `Turn.extract/4`, `Turn.query/4`) does on an external backend, and how the guarantee's
  scope gets qualified in this README and in `Manifold.Clause`'s moduledoc once that
  backend lands.
  It is infrastructure, not a conversation input: it never appears in `kb_snapshot`
  and is not written to the conversation's log. `priv/prelude.pl` ships one example:
  the textbook "why" meta-interpreter (Sterling & Shapiro, *The Art of Prolog*) —
  `solve/2`/`why/2`, which prove a goal the same way `clause/2` recursion always has,
  but keep the derivation instead of discarding it, so `?- why(mortal(socrates), Proof)`
  in question mode answers with *how*, not just *whether*. Point
  `MANIFOLD_PRELUDE=priv/prelude.pl` at it to try it, or read the file's header for
  the design.
- **Automated test suite.** `test/` has three tiers — pure unit tests that need
  no sidecar (`test/manifold/`), integration tests that drive a real `swipl`
  (`test/integration/`, tagged `:swipl`), and one-shot smoke tests that verify
  OS-level assumptions (`test/smoke/`, excluded from `mix test` by default). Run
  with `mix test`; see `CLAUDE.md` for the full rationale.
