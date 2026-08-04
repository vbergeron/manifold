# Manifold

A conversational AI whose every conversation is **doubled** by a live Prolog
session. Natural-language dialogue on one side; a persistent, inspectable Prolog
knowledge base on the other. Facts and rules distilled from the conversation are
`assert`ed into the KB, and the model reasons by *querying* it — deterministic
inference, persistent symbolic state, and contradiction/consistency checking
that a pure-LLM chat cannot give reliably.

## Architecture

Manifold is an Elixir/OTP application that supervises two sidecar servers as
**independent OS processes**, each in its own `Port`, each restarted on its own:

```
Manifold.Supervisor                (one_for_one)
├── Manifold.Prolog.Server          swipl MQI server   — the knowledge base
├── Manifold.Llama.Server           llama.cpp server   — the language model
├── Manifold.Conversation.Registry  conversation_id -> pid, for reconnects
├── Manifold.Conversation.Supervisor (DynamicSupervisor)
│   └── Manifold.Conversation …      one process per conversation:
│                                    NL transcript + its own Prolog KB connection
│       └── Manifold.Turn            the turn loop, spawned + monitored per turn
└── Bandit                          HTTP/WebSocket endpoint (Manifold.Web.Router)
```

Why Elixir: the design is per-conversation, long-lived, stateful, isolated
processes — OTP's home turf. Crucially, an MQI connection can be bounded
per-query and, worst case, the whole engine killed by restarting the supervised
process. That makes **runaway (non-terminating) Prolog queries survivable** —
something an in-process embedding can't safely do.

### Key modules

| Module | Role |
|--------|------|
| `Manifold.Application`  | Supervision tree (the two sidecars, conversations, and the endpoint). |
| `Manifold.OsProcess`    | Owns an OS process via a `Port`; a sh guardian kills the child on BEAM death or SIGTERM, so no sidecar is ever orphaned. |
| `Manifold.Llama.Server` | Supervised `llama-server`; polls `/health`; parks in `:no_model` if no GGUF is present. |
| `Manifold.Llama.Client` | HTTP client; `:grammar` option sends a **GBNF** string for constrained decoding; `stream/3` for token-by-token. |
| `Manifold.Prolog.Server`| Supervised `swipl` MQI server (accept loop on the main thread). |
| `Manifold.Prolog.MQI`   | MQI wire protocol (length-prefixed frames, JSON answers). |
| `Manifold.Prolog.Answer`| Decodes MQI answers into `true` / `false` / bindings, and picks a witness. |
| `Manifold.Conversation` | The "doubling" unit: typed transcript + a dedicated KB connection. Single source of truth for both UI panels. |
| `Manifold.Turn`         | The turn loop (below), run in its own monitored process so cancel is a kill. |
| `Manifold.Gate`         | The one cheap classification — lexical, no model call: `{new_facts?, needs_query?}` + the sentence split. |
| `Manifold.Prompt`       | The three prompts: `extract/2`, `goals/2`, `respond/1`. |
| `Manifold.Clause`       | Prolog source as data: normalize, classify `fact`/`rule`/`constraint`, split, signatures. Also refuses the one unsound shape the grammar can't exclude — a fact carrying a variable, which would hold for every term. |
| `Manifold.Grammar`      | The Prolog GBNF (`priv/grammar/prolog.gbnf`), embedded at compile time. |
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
[GATE]  one lexical pass, no model → {new_facts?: bool, needs_query?: bool}
     │   (classifies the message: chitchat / statement / question / mixed)
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

1. **Gate once, up front.** Both booleans are decided by a single deterministic
   lexical pass over the message — no model call, so it is free and instant (the
   rules are in `Manifold.Gate`, deliberately written so a learned gate could
   replace them without the rest of the loop noticing). The four outcomes are
   chitchat / pure statement / pure question / mixed. Abstention ("no facts",
   "no queries") is a first-class, normal result — which is *why the grammar can
   stay strict* (`clause+`): it is only ever invoked once the gate has committed
   to producing clauses.
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

Not yet built:

- **KB persistence to disk per conversation.** `Manifold.Conversation` holds the
  KB and transcript in memory only, and is `restart: :transient` — a crash or a
  BEAM restart loses both, and a reconnecting `open {conversation_id}` then finds
  a fresh, empty conversation under that id.
- **An automated test suite.** There is no `test/` tree yet; verification is the
  scripts above, which need a live `swipl` and (for the LLM phases) a model. The
  pure parts — `Clause`, `Prolog.MQI` framing, `Prolog.Answer`, `Event` — are
  unit-testable without either sidecar.
