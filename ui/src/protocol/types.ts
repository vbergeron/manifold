/**
 * Manifold UI ⇄ Server protocol, v1.
 * Mirrors docs/PROTOCOL.md. Keep in lockstep with it.
 */

export const PROTOCOL_VERSION = 1;

/* ------------------------------------------------------------------ envelope */

/** Every frame, both directions. `seq` is server→client only. */
export interface Envelope<TType extends string, TPayload> {
  v: typeof PROTOCOL_VERSION;
  type: TType;
  /** Monotonic, server→client only; absent on client→server frames. */
  seq?: number;
  /** Correlates events of one user turn; null for session-level frames. */
  turn: string | null;
  /** Epoch milliseconds. */
  ts: number;
  payload: TPayload;
}

/* ---------------------------------------------------------------- data model */

export type ClauseKind = "fact" | "rule" | "constraint";

/** A Prolog clause in the conversation's knowledge base (left panel). */
export interface Clause {
  /** Server-assigned and stable. */
  id: string;
  text: string;
  kind: ClauseKind;
  /** Turn that introduced it; null for pre-seeded clauses. */
  turn: string | null;
}

/** One variable→value solution row of a Prolog query. */
export type Binding = Record<string, unknown>;

/** `true` | `false` | a set of solution bindings. */
export type QueryAnswer = boolean | { bindings: Binding[] };

interface MessageBase {
  id: string;
  turn: string | null;
}

export interface UserMessage extends MessageBase {
  kind: "user";
  text: string;
}

export interface AssistantMessage extends MessageBase {
  kind: "assistant";
  text: string;
}

/** A Prolog goal that was run, plus its answer. Rendered as a reasoning chip. */
export interface QueryMessage extends MessageBase {
  kind: "query";
  goal: string;
  answer: QueryAnswer;
}

/** A violated integrity constraint. Rendered prominently. */
export interface ContradictionMessage extends MessageBase {
  kind: "contradiction";
  constraint: string;
  witness: Record<string, unknown>;
  /** The clause whose assertion made the constraint body provable. */
  offending?: string;
}

/** Tagged union on `kind` — the right panel's transcript entries. */
export type TranscriptMessage =
  | UserMessage
  | AssistantMessage
  | QueryMessage
  | ContradictionMessage;

export type MessageKind = TranscriptMessage["kind"];

/* ------------------------------------------------------- server → client */

export type TurnPhase =
  | "gate"
  | "extract"
  | "assert"
  | "check"
  | "query"
  | "respond";

export const TURN_PHASES: readonly TurnPhase[] = [
  "gate",
  "extract",
  "assert",
  "check",
  "query",
  "respond",
];

export type ErrorCode =
  | "llama_unavailable"
  | "prolog_unavailable"
  | "prolog_timeout"
  | "grammar_parse_failed"
  | "bad_message"
  /** Server declined to open a new conversation; the socket closes with 1013 and the
   *  normal backoff reconnect retries the same conversation. */
  | "at_capacity"
  | "internal";

export interface SessionPayload {
  conversation_id: string;
  /** `prolog` is *this conversation's* engine, not a shared server — each conversation
   *  owns its own swipl process. */
  sidecars: { llama: boolean; prolog: boolean };
}

export interface KbSnapshotPayload {
  clauses: Clause[];
}

export interface FlaggedClause {
  id: string;
  reason: string;
}

export interface KbDeltaPayload {
  added?: Clause[];
  retracted?: string[];
  flagged?: FlaggedClause[];
}

export interface TranscriptSnapshotPayload {
  messages: TranscriptMessage[];
}

export interface GateResultPayload {
  new_facts: boolean;
  needs_query: boolean;
}

export interface ClausesExtractedPayload {
  clauses: Clause[];
}

export interface AssistantTokenPayload {
  id: string;
  text: string;
}

export interface AssistantMessagePayload {
  id: string;
  text: string;
  done: true;
}

export interface ErrorPayload {
  code: ErrorCode;
  message: string;
}

export type ServerFrame =
  | Envelope<"session", SessionPayload>
  | Envelope<"kb_snapshot", KbSnapshotPayload>
  | Envelope<"kb_delta", KbDeltaPayload>
  | Envelope<"transcript_snapshot", TranscriptSnapshotPayload>
  | Envelope<"turn_started", Record<string, never>>
  | Envelope<"turn_phase", { phase: TurnPhase }>
  | Envelope<"gate_result", GateResultPayload>
  | Envelope<"clauses_extracted", ClausesExtractedPayload>
  | Envelope<"message", TranscriptMessage>
  | Envelope<"assistant_token", AssistantTokenPayload>
  | Envelope<"assistant_message", AssistantMessagePayload>
  | Envelope<"turn_done", Record<string, never>>
  | Envelope<"error", ErrorPayload>;

export type ServerFrameType = ServerFrame["type"];

/* ------------------------------------------------------- client → server */

export type ClientFrame =
  | Envelope<"open", { conversation_id: string | null }>
  | Envelope<"user_message", { text: string }>
  | Envelope<"cancel_turn", Record<string, never>>
  | Envelope<"kb_request", Record<string, never>>;

/**
 * `Omit` collapses a discriminated union into one flat object, which would let
 * a `type` be paired with the wrong `payload`. Distribute over the union so the
 * pairing stays checked.
 */
export type DistributiveOmit<T, K extends PropertyKey> = T extends unknown
  ? Omit<T, K>
  : never;

/** A client→server frame minus the fields the transport fills in. */
export type OutboundFrame = DistributiveOmit<ClientFrame, "v" | "ts">;

/** A server→client frame minus the fields a fake server fills in. */
export type ServerFrameBody = DistributiveOmit<ServerFrame, "v" | "seq" | "ts">;

/* ------------------------------------------------------------------ helpers */

const SERVER_FRAME_TYPES: ReadonlySet<string> = new Set<ServerFrameType>([
  "session",
  "kb_snapshot",
  "kb_delta",
  "transcript_snapshot",
  "turn_started",
  "turn_phase",
  "gate_result",
  "clauses_extracted",
  "message",
  "assistant_token",
  "assistant_message",
  "turn_done",
  "error",
]);

/**
 * Structural check on an inbound frame. Deliberately shallow: the server is
 * authoritative on payload shape, we only guard the envelope so a stray frame
 * can't crash the reducer.
 */
export function parseServerFrame(raw: string): ServerFrame | null {
  let value: unknown;
  try {
    value = JSON.parse(raw);
  } catch {
    return null;
  }
  if (typeof value !== "object" || value === null) return null;
  const frame = value as Record<string, unknown>;
  if (frame["v"] !== PROTOCOL_VERSION) return null;
  if (typeof frame["type"] !== "string") return null;
  if (!SERVER_FRAME_TYPES.has(frame["type"])) return null;
  if (typeof frame["payload"] !== "object" || frame["payload"] === null) {
    return null;
  }
  return frame as unknown as ServerFrame;
}

let turnCounter = 0;

/** The client mints the `turn` id for `user_message`. */
export function mintTurnId(): string {
  turnCounter += 1;
  const stamp = Date.now().toString(36);
  return `t_${stamp}_${turnCounter}`;
}

export function answerIsBindings(
  answer: QueryAnswer,
): answer is { bindings: Binding[] } {
  return typeof answer === "object" && answer !== null && "bindings" in answer;
}

/**
 * True when `text` opens **question mode**: sent straight to Prolog as a raw
 * goal instead of to the model. Mirrors `Manifold.Clause.question?/1` — kept
 * in lockstep with it since both sides must agree on what counts as one.
 */
export function isQuestionMode(text: string): boolean {
  return text.trimStart().startsWith("?");
}
