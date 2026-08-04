# Manifold UI ⇄ Server Protocol (v1)

The web UI has two panels, each backed by a server-authoritative structure:

- **Left — Knowledge Base**: the conversation's Prolog clauses (facts, rules,
  integrity constraints). Read-only in v1. Snapshot on connect + live deltas.
- **Right — Chat**: a typed transcript. Normal user/assistant bubbles **plus
  special message kinds**: `query` (a Prolog goal + its answer) and
  `contradiction` (a violated integrity constraint). The assistant reply
  streams token-by-token.

A turn is **not** request/response — it is a multi-phase, long-running process
(gate → extract → assert → check → query → respond) that emits a stream of typed
events. The KB mutates on the left *while* the reply streams on the right; that
live doubling is the point.

## Transport

- **WebSocket, one connection ⇄ one conversation**, upgraded via **Bandit +
  `WebSockAdapter`** (a `Manifold.Web.Socket` WebSock handler; one handler
  process per socket, *monitoring* — not linked to — the conversation's
  `Manifold.Conversation`, which has to outlive the socket for reconnects to
  have anything to re-attach to).
- **Keepalive is ours**: server sends a WebSocket `ping` every ~30 s; a missed
  `pong` past an idle deadline closes the socket. (No Phoenix heartbeat layer.)
- **Framing is ours**: one JSON object per text frame, the envelope below.

## Envelope

Every frame, both directions:

```json
{ "v": 1, "type": "user_message", "seq": 42, "turn": "t_7", "ts": 1730000000123, "payload": { } }
```

| field | meaning |
|-------|---------|
| `v`   | protocol version (currently 1) |
| `type`| message discriminator |
| `seq` | monotonic counter, **server→client only**; client detects gaps/dedupes |
| `turn`| correlates every event belonging to one user turn (nullable for session-level frames) |
| `ts`  | epoch milliseconds |
| `payload` | type-specific body (below) |

## Data model

**KB clause** (left panel):
```json
{ "id": "c12", "text": "mortal(X) :- human(X).", "kind": "rule", "turn": "t_7" }
```
`kind` ∈ `fact` | `rule` | `constraint`. `id` is server-assigned and stable.

**Transcript message** (right panel) — a tagged union on `kind`:
```json
{ "id": "m34", "kind": "user",          "turn": "t_7", "text": "..." }
{ "id": "m35", "kind": "assistant",     "turn": "t_7", "text": "..." }
{ "id": "m36", "kind": "query",         "turn": "t_7", "goal": "mortal(socrates)", "answer": true }
{ "id": "m37", "kind": "contradiction", "turn": "t_8", "constraint": ":- whale(A),fish(A).", "witness": {"A":"willy"}, "offending": "fish(willy)." }
```
`answer` ∈ `true` | `false` | `{"bindings": [...]}`. `query` and `contradiction`
are the special messages, rendered distinctly.

## Server → Client events

| type | payload | effect |
|------|---------|--------|
| `session` | `{conversation_id, sidecars:{llama:bool, prolog:bool}}` | handshake result |
| `kb_snapshot` | `{clauses:[clause]}` | (re)initialise left panel |
| `kb_delta` | `{added:[clause], retracted:[id], flagged:[{id,reason}]}` | mutate left panel |
| `transcript_snapshot` | `{messages:[message]}` | (re)initialise right panel |
| `turn_started` | `{}` | begin turn (turn id in envelope) |
| `turn_phase` | `{phase}` — gate\|extract\|assert\|check\|query\|respond | activity indicator |
| `gate_result` | `{new_facts:bool, needs_query:bool}` | debug/telemetry |
| `clauses_extracted` | `{clauses:[clause]}` | preview before assert |
| `message` | one transcript `message` (kind user\|query\|contradiction, or a completed assistant) | append to right panel |
| `assistant_token` | `{id, text}` | append token to assistant message `id` |
| `assistant_message` | `{id, text, done:true}` | finalise assistant message `id` |
| `turn_done` | `{}` | end of turn |
| `error` | `{code, message}` | typed failure (see below) |

Notes: a `query` or `contradiction` transcript entry is delivered as a `message`
event (persisted, with its own `id`). The streamed assistant reply is
`assistant_token`* then a terminating `assistant_message`.

## Client → Server commands

| type | payload | meaning |
|------|---------|---------|
| `open` | `{conversation_id \| null}` | attach to a conversation (null = create new) |
| `user_message` | `{text}` | start a turn (client mints the `turn` id in the envelope) |
| `cancel_turn` | `{}` | abort the in-flight turn (see semantics) |
| `kb_request` | `{}` | ask server to re-send `kb_snapshot` |

(No `retract` in v1 — the KB is read-only.)

## One turn, concretely

User: *"Socrates is a human. Is he mortal?"*

```
C→S user_message      {turn:t7, text:"Socrates is a human. Is he mortal?"}
S→C turn_started      {t7}
S→C message           {t7, m34, kind:user, text:"Socrates is a human. Is he mortal?"}
S→C turn_phase        {t7, gate}    · gate_result {t7, new_facts:true, needs_query:true}
S→C turn_phase        {t7, extract} · clauses_extracted {t7, [human(socrates).]}
S→C turn_phase        {t7, assert}  · kb_delta {added:[{id:c12, text:"human(socrates).", kind:fact}]}
S→C turn_phase        {t7, check}   (no contradiction)
S→C turn_phase        {t7, query}   · message {t7, m36, kind:query, goal:"mortal(socrates)", answer:true}
S→C turn_phase        {t7, respond} · assistant_token {m37,"Yes"} …
S→C assistant_message {t7, m37, text:"Yes — via mortal(X) :- human(X).", done:true}
S→C turn_done         {t7}
```

Contradiction path (per the sealed override rule): a `check` phase that fails
emits a `message {kind:contradiction, …}` *and* steers the `respond` phase to
explain it.

## Reconnect

The server owns all state (in the `Conversation` process). On reconnect the
client sends `open {conversation_id}`; the server replies:

```
session → kb_snapshot → transcript_snapshot → (resume live events)
```

`seq` lets the client discard any duplicate it already applied. No fragile
server-side replay buffer is required.

## Cancel semantics

`cancel_turn` stops the remaining phases, aborts llama generation, and kills any
running Prolog query (the per-query timeout / process kill switch). Clauses
already asserted earlier in the turn **remain** (KB is append-only from turns in
v1); the server emits `turn_done` to close the turn.

## Errors

Errors are typed events, never silent drops:

| `code` | when |
|--------|------|
| `llama_unavailable` | model not loaded / server down |
| `prolog_unavailable` | MQI server down |
| `prolog_timeout` | a query hit its time cap |
| `grammar_parse_failed` | model output could not be parsed (should be rare under GBNF) |
| `bad_message` | malformed/unknown client frame |
| `internal` | unexpected server error |

## Versioning

`v` is bumped on any breaking change to the envelope or message semantics. The
server rejects an unknown `v` with `error {code:"bad_message"}` at `open`.

---

**Implementation status:** built, both sides.

| Piece | Where |
|-------|-------|
| Transport / upgrade | `Manifold.Web.Router` (`GET /socket`), Bandit + `WebSockAdapter` |
| Envelope, `seq`, keepalive | `Manifold.Web.Socket` (30 s ping, 95 s idle deadline) |
| Envelope construction / emission | `Manifold.Event` |
| Clauses with stable `id`/`kind`/`turn`, typed transcript, snapshots | `Manifold.Conversation` |
| Phase events, in the order above | `Manifold.Turn` |
| Client | `ui/src/protocol/{types,client}.ts` + `ui/src/state/store.ts` |

Verified end to end by `scripts/ws_smoke.exs`, which drives the turn loop
directly and then speaks this protocol over a real socket.

Not in v1, as specified above: `retract` (the KB is append-only), and any
server-side persistence — all state lives in the `Conversation` process, so it is
lost if that process dies.
