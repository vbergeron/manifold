import {
  type Clause,
  type ErrorPayload,
  type ServerFrame,
  type TranscriptMessage,
  type TurnPhase,
} from "../protocol/types";
import type { ConnectionStatus } from "../protocol/client";

/* ------------------------------------------------------------------- state */

export interface ClauseView extends Clause {
  /** Set by `kb_delta.flagged` — a violated/contradicting clause. */
  flaggedReason: string | null;
  /** True while the add-highlight animation should be shown. */
  isNew: boolean;
  /** Extracted but not yet asserted (`clauses_extracted` preview). */
  pending: boolean;
}

export interface MessageView {
  message: TranscriptMessage;
  /** Assistant message still receiving tokens. */
  streaming: boolean;
}

export interface TurnState {
  id: string;
  phase: TurnPhase | null;
  gate: { new_facts: boolean; needs_query: boolean } | null;
  /** True between `turn_started` (or local optimistic send) and `turn_done`. */
  active: boolean;
}

export interface ErrorEntry {
  id: number;
  code: ErrorPayload["code"];
  message: string;
  ts: number;
}

export interface State {
  status: ConnectionStatus;
  conversationId: string | null;
  sidecars: { llama: boolean; prolog: boolean } | null;
  /** Highest applied server `seq`; frames at or below it are duplicates. */
  lastSeq: number;
  clauseOrder: string[];
  clauses: Record<string, ClauseView>;
  messageOrder: string[];
  messages: Record<string, MessageView>;
  turn: TurnState | null;
  errors: ErrorEntry[];
}

export const initialState: State = {
  status: "connecting",
  conversationId: null,
  sidecars: null,
  lastSeq: 0,
  clauseOrder: [],
  clauses: {},
  messageOrder: [],
  messages: {},
  turn: null,
  errors: [],
};

/* ------------------------------------------------------------------ actions */

export type Action =
  | { type: "status"; status: ConnectionStatus }
  | { type: "frame"; frame: ServerFrame }
  /** Optimistic local turn start, so Cancel appears without waiting for a RTT. */
  | { type: "local_turn"; turn: string }
  | { type: "clear_new"; ids: string[] }
  | { type: "dismiss_error"; id: number };

let errorSeq = 0;

/* ----------------------------------------------------------------- reducer */

export function reducer(state: State, action: Action): State {
  switch (action.type) {
    case "status":
      return state.status === action.status
        ? state
        : { ...state, status: action.status };

    case "local_turn":
      return {
        ...state,
        turn: { id: action.turn, phase: null, gate: null, active: true },
      };

    case "clear_new":
      return clearNew(state, action.ids);

    case "dismiss_error":
      return {
        ...state,
        errors: state.errors.filter((e) => e.id !== action.id),
      };

    case "frame":
      return applyFrame(state, action.frame);
  }
}

function applyFrame(state: State, frame: ServerFrame): State {
  const seq = frame.seq;

  // A `session` frame opens every (re)connect handshake; it is also the only
  // safe point to adopt a lower seq watermark (server renumbered its stream).
  if (frame.type === "session") {
    const next: State = {
      ...state,
      conversationId: frame.payload.conversation_id,
      sidecars: frame.payload.sidecars,
      lastSeq: typeof seq === "number" ? seq : state.lastSeq,
    };
    return next;
  }

  if (typeof seq === "number") {
    if (seq <= state.lastSeq) return state; // duplicate — already applied
    state = { ...state, lastSeq: seq };
  }

  switch (frame.type) {
    case "kb_snapshot":
      return { ...state, ...buildKb(frame.payload.clauses) };

    case "kb_delta":
      return applyKbDelta(state, frame.payload);

    case "transcript_snapshot":
      return { ...state, ...buildTranscript(frame.payload.messages) };

    case "turn_started":
      return {
        ...state,
        turn: {
          id: frame.turn ?? state.turn?.id ?? "",
          phase: null,
          gate: null,
          active: true,
        },
      };

    case "turn_phase":
      return {
        ...state,
        turn: {
          id: frame.turn ?? state.turn?.id ?? "",
          phase: frame.payload.phase,
          gate: state.turn?.gate ?? null,
          active: true,
        },
      };

    case "gate_result":
      return {
        ...state,
        turn: {
          id: frame.turn ?? state.turn?.id ?? "",
          phase: state.turn?.phase ?? null,
          gate: {
            new_facts: frame.payload.new_facts,
            needs_query: frame.payload.needs_query,
          },
          active: true,
        },
      };

    case "clauses_extracted":
      return addPendingClauses(state, frame.payload.clauses, frame.turn);

    case "message":
      return upsertMessage(state, frame.payload, false);

    case "assistant_token":
      return appendToken(state, frame.payload.id, frame.payload.text, frame.turn);

    case "assistant_message":
      return upsertMessage(
        state,
        {
          id: frame.payload.id,
          kind: "assistant",
          turn: frame.turn,
          text: frame.payload.text,
        },
        false,
      );

    case "turn_done":
      return {
        ...state,
        ...dropPending(state),
        turn: state.turn ? { ...state.turn, active: false, phase: null } : null,
        messages: finalizeStreaming(state.messages),
      };

    case "error":
      return {
        ...state,
        errors: [
          ...state.errors.slice(-4),
          {
            id: (errorSeq += 1),
            code: frame.payload.code,
            message: frame.payload.message,
            ts: frame.ts,
          },
        ],
      };
  }
}

/* ------------------------------------------------------------------- KB ops */

function buildKb(clauses: Clause[]): Pick<State, "clauseOrder" | "clauses"> {
  const order: string[] = [];
  const byId: Record<string, ClauseView> = {};
  for (const clause of clauses) {
    if (byId[clause.id]) continue;
    order.push(clause.id);
    byId[clause.id] = {
      ...clause,
      flaggedReason: null,
      isNew: false,
      pending: false,
    };
  }
  return { clauseOrder: order, clauses: byId };
}

function applyKbDelta(
  state: State,
  delta: { added?: Clause[]; retracted?: string[]; flagged?: { id: string; reason: string }[] },
): State {
  let order = state.clauseOrder;
  const byId = { ...state.clauses };

  if (delta.added?.length) {
    const appended: string[] = [];
    for (const clause of delta.added) {
      const existing = byId[clause.id];
      if (!existing) appended.push(clause.id);
      byId[clause.id] = {
        ...clause,
        flaggedReason: existing?.flaggedReason ?? null,
        isNew: true,
        pending: false,
      };
    }
    if (appended.length) order = [...order, ...appended];
  }

  if (delta.retracted?.length) {
    const gone = new Set(delta.retracted);
    for (const id of gone) delete byId[id];
    order = order.filter((id) => !gone.has(id));
  }

  if (delta.flagged?.length) {
    for (const { id, reason } of delta.flagged) {
      const existing = byId[id];
      if (existing) byId[id] = { ...existing, flaggedReason: reason };
    }
  }

  return { ...state, clauseOrder: order, clauses: byId };
}

/** `clauses_extracted` is a preview: show it, greyed, until `assert` lands. */
function addPendingClauses(
  state: State,
  clauses: Clause[],
  turn: string | null,
): State {
  const byId = { ...state.clauses };
  const appended: string[] = [];
  for (const clause of clauses) {
    if (byId[clause.id]) continue;
    appended.push(clause.id);
    byId[clause.id] = {
      ...clause,
      turn: clause.turn ?? turn,
      flaggedReason: null,
      isNew: false,
      pending: true,
    };
  }
  if (!appended.length) return state;
  return {
    ...state,
    clauseOrder: [...state.clauseOrder, ...appended],
    clauses: byId,
  };
}

function dropPending(state: State): Pick<State, "clauseOrder" | "clauses"> {
  const stale = state.clauseOrder.filter((id) => state.clauses[id]?.pending);
  if (!stale.length) {
    return { clauseOrder: state.clauseOrder, clauses: state.clauses };
  }
  const byId = { ...state.clauses };
  for (const id of stale) delete byId[id];
  return {
    clauseOrder: state.clauseOrder.filter((id) => !stale.includes(id)),
    clauses: byId,
  };
}

function clearNew(state: State, ids: string[]): State {
  let changed = false;
  const byId = { ...state.clauses };
  for (const id of ids) {
    const clause = byId[id];
    if (clause?.isNew) {
      byId[id] = { ...clause, isNew: false };
      changed = true;
    }
  }
  return changed ? { ...state, clauses: byId } : state;
}

/* ------------------------------------------------------------ transcript ops */

function buildTranscript(
  messages: TranscriptMessage[],
): Pick<State, "messageOrder" | "messages"> {
  const order: string[] = [];
  const byId: Record<string, MessageView> = {};
  for (const message of messages) {
    if (byId[message.id]) continue;
    order.push(message.id);
    byId[message.id] = { message, streaming: false };
  }
  return { messageOrder: order, messages: byId };
}

function upsertMessage(
  state: State,
  message: TranscriptMessage,
  streaming: boolean,
): State {
  const existing = state.messages[message.id];
  const messages = {
    ...state.messages,
    [message.id]: { message, streaming },
  };
  return {
    ...state,
    messages,
    messageOrder: existing
      ? state.messageOrder
      : [...state.messageOrder, message.id],
  };
}

/**
 * Tokens may arrive before any `message` event created the assistant entry,
 * so this creates it on demand and appends.
 */
function appendToken(
  state: State,
  id: string,
  text: string,
  turn: string | null,
): State {
  const existing = state.messages[id];
  if (!existing) {
    return upsertMessage(state, { id, kind: "assistant", turn, text }, true);
  }
  if (existing.message.kind !== "assistant") return state;
  return {
    ...state,
    messages: {
      ...state.messages,
      [id]: {
        message: { ...existing.message, text: existing.message.text + text },
        streaming: true,
      },
    },
  };
}

function finalizeStreaming(
  messages: Record<string, MessageView>,
): Record<string, MessageView> {
  let changed = false;
  const next = { ...messages };
  for (const [id, view] of Object.entries(messages)) {
    if (view.streaming) {
      next[id] = { ...view, streaming: false };
      changed = true;
    }
  }
  return changed ? next : messages;
}

/* ---------------------------------------------------------------- selectors */

export function selectClauses(state: State): ClauseView[] {
  const out: ClauseView[] = [];
  for (const id of state.clauseOrder) {
    const clause = state.clauses[id];
    if (clause) out.push(clause);
  }
  return out;
}

export function selectMessages(state: State): MessageView[] {
  const out: MessageView[] = [];
  for (const id of state.messageOrder) {
    const view = state.messages[id];
    if (view) out.push(view);
  }
  return out;
}

/** Renders one Prolog binding value for display. */
export function stringifyValue(value: unknown): string {
  if (typeof value === "string") return value;
  if (value === null || value === undefined) return "_";
  if (typeof value === "number" || typeof value === "boolean") {
    return String(value);
  }
  return JSON.stringify(value);
}
