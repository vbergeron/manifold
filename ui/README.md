# Manifold UI

The web frontend for Manifold: a two-panel view of a conversation and the live
Prolog knowledge base that doubles it. Vite + React + TypeScript, no UI kit.

Implements `docs/PROTOCOL.md` (v1) exactly. The server is authoritative for all
state; this app renders snapshots and applies deltas.

## Run

```sh
cd ui
mise install                     # Node 22 (pinned in ui/mise.toml)
mise exec -- npm install
mise exec -- npm run dev         # http://localhost:5173
```

Other scripts: `npm run typecheck`, `npm run build` (typechecks, then bundles to
`dist/`), `npm run preview`.

### Connection

Connects to **`ws://127.0.0.1:4000/socket`**. Override with `VITE_WS_URL` (see
`.env.example`):

```sh
echo 'VITE_WS_URL=ws://127.0.0.1:4001/socket' > .env.local
```

One WebSocket ⇄ one conversation. On connect it sends
`open {conversation_id: null}`; on every reconnect it re-sends `open` with the id
from the `session` event, so the same conversation is re-attached rather than a
new one created. Reconnect is automatic with exponential backoff (0.5 s → 15 s,
jittered).

### Without a server

A scripted fake event feed drives the UI when the backend isn't running:

```sh
mise exec -- npm run dev              # then open http://localhost:5173/?mock=1
# or: VITE_MOCK=1 mise exec -- npm run dev
```

It plays two turns — an inference path and a contradiction path — through all six
phases, with token streaming. It is a `SocketLike` implementation swapped in at
the socket factory, so app code has no mock branch, and it is compiled out of
production builds (`import.meta.env.DEV` guard in `src/config.ts`).

## Layout

```
src/
  config.ts              WS_URL + dev-only mock flag
  main.tsx               root render
  App.tsx                shell: topbar (session/sidecars/connection) + two panels
  useTheme.ts            light/dark/system, persisted
  protocol/
    types.ts             envelope, clause, transcript union, every event payload
    client.ts            ManifoldClient: lifecycle, re-open, backoff, SocketLike
  state/
    store.ts             reducer + selectors (seq dedupe, id-keyed maps)
    useManifold.ts       wires client ⇄ reducer, exposes send/cancel/refresh
  components/
    KbPanel.tsx          left: clauses grouped by kind, highlight/flag/pending
    ChatPanel.tsx        right: transcript, autoscroll, phase indicator, composer
    MessageView.tsx      bubbles + query chip + contradiction card
    Composer.tsx         input, Send, Cancel (while a turn is in flight)
    PhaseIndicator.tsx   gate › extract › assert › check › query › respond
    ConnectionBadge.tsx  live/reconnecting/disconnected + manual retry
    ErrorStack.tsx       typed `error` events as dismissible toasts
  mock/mockSocket.ts     dev-only fake server
```

### How state is kept

- KB clauses keyed by `clause.id`, insertion-ordered; `kb_snapshot` replaces,
  `kb_delta` mutates (`added` highlights for ~2.6 s, `retracted` removes,
  `flagged` styles as a contradiction).
- Transcript messages keyed by `message.id`; `assistant_token` accumulates into
  the message with that id (creating it if tokens arrive first),
  `assistant_message` finalises it.
- `seq` is a watermark: any frame at or below the last applied `seq` is dropped.
  A `session` frame — which opens every (re)connect handshake — adopts its own
  `seq`, so a server that renumbers its stream per connection still works.
- `clauses_extracted` renders as a dashed "extracted" preview in the KB panel and
  is cleared at `turn_done` if `assert` never confirmed it.
