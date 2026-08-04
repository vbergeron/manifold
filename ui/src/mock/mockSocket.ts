/**
 * Dev-only fake server. Implements `SocketLike`, so it exercises the exact
 * same client/reducer path as a real connection — no branches in app code.
 * Enabled via `?mock=1` or `VITE_MOCK=1`; see src/config.ts.
 */
import type { SocketLike } from "../protocol/client";
import {
  PROTOCOL_VERSION,
  type Clause,
  type ServerFrameBody,
  type TranscriptMessage,
  type TurnPhase,
} from "../protocol/types";

type Step = { after: number; frames: ServerFrameBody[] };

const SEED_CLAUSES: Clause[] = [
  { id: "c1", text: "human(socrates).", kind: "fact", turn: "t_seed" },
  { id: "c2", text: "mortal(X) :- human(X).", kind: "rule", turn: "t_seed" },
  { id: "c3", text: ":- whale(A), fish(A).", kind: "constraint", turn: "t_seed" },
];

const SEED_MESSAGES: TranscriptMessage[] = [
  {
    id: "m1",
    kind: "user",
    turn: "t_seed",
    text: "Socrates is a human, and every human is mortal.",
  },
  {
    id: "m2",
    kind: "assistant",
    turn: "t_seed",
    text: "Noted — I've asserted human(socrates) and the rule mortal(X) :- human(X).",
  },
];

export class MockSocket implements SocketLike {
  onopen: ((this: unknown, ev: unknown) => void) | null = null;
  onmessage: ((this: unknown, ev: { data: unknown }) => void) | null = null;
  onclose: ((this: unknown, ev: unknown) => void) | null = null;
  onerror: ((this: unknown, ev: unknown) => void) | null = null;

  private seq = 0;
  private ids = 0;
  private closed = false;
  private timers = new Set<ReturnType<typeof setTimeout>>();
  private clauses: Clause[] = SEED_CLAUSES.map((c) => ({ ...c }));
  private transcript: TranscriptMessage[] = SEED_MESSAGES.map((m) => ({ ...m }));
  private activeTurn: string | null = null;
  private scenario = 0;

  constructor() {
    this.later(120, () => this.onopen?.call(this, {}));
  }

  send(data: string): void {
    if (this.closed) return;
    let frame: { type?: string; turn?: string | null; payload?: unknown };
    try {
      frame = JSON.parse(data);
    } catch {
      return;
    }
    switch (frame.type) {
      case "open":
        return this.handleOpen();
      case "kb_request":
        return this.emit({
          type: "kb_snapshot",
          turn: null,
          payload: { clauses: this.clauses },
        });
      case "user_message":
        return this.handleUserMessage(
          frame.turn ?? "t_?",
          String((frame.payload as { text?: string })?.text ?? ""),
        );
      case "cancel_turn":
        return this.handleCancel();
      default:
        return this.emit({
          type: "error",
          turn: null,
          payload: { code: "bad_message", message: `unknown type ${frame.type}` },
        });
    }
  }

  close(): void {
    if (this.closed) return;
    this.closed = true;
    this.clearTimers();
    this.onclose?.call(this, { code: 1000 });
  }

  /* ------------------------------------------------------------- scenarios */

  private handleOpen(): void {
    this.emit({
      type: "session",
      turn: null,
      payload: {
        conversation_id: "conv_mock_1",
        sidecars: { llama: true, prolog: true },
      },
    });
    this.emit({
      type: "kb_snapshot",
      turn: null,
      payload: { clauses: this.clauses },
    });
    this.emit({
      type: "transcript_snapshot",
      turn: null,
      payload: { messages: this.transcript },
    });
  }

  private handleUserMessage(turn: string, text: string): void {
    this.activeTurn = turn;
    const contradiction =
      /whale|fish|not\b|isn't|doesn't/i.test(text) || this.scenario % 2 === 1;
    this.scenario += 1;
    const steps = contradiction
      ? this.contradictionScript(turn, text)
      : this.inferenceScript(turn, text);
    this.run(turn, steps);
  }

  private inferenceScript(turn: string, text: string): Step[] {
    const userId = this.nextId("m");
    const queryId = this.nextId("m");
    const replyId = this.nextId("m");
    const factId = this.nextId("c");
    const fact: Clause = {
      id: factId,
      text: "philosopher(socrates).",
      kind: "fact",
      turn,
    };
    return [
      { after: 60, frames: [{ type: "turn_started", turn, payload: {} }] },
      {
        after: 40,
        frames: [
          { type: "message", turn, payload: { id: userId, kind: "user", turn, text } },
        ],
      },
      { after: 200, frames: [this.phase(turn, "gate")] },
      {
        after: 320,
        frames: [
          {
            type: "gate_result",
            turn,
            payload: { new_facts: true, needs_query: true },
          },
        ],
      },
      {
        after: 200,
        frames: [
          this.phase(turn, "extract"),
          { type: "clauses_extracted", turn, payload: { clauses: [fact] } },
        ],
      },
      {
        after: 500,
        frames: [
          this.phase(turn, "assert"),
          { type: "kb_delta", turn, payload: { added: [fact] } },
        ],
      },
      { after: 350, frames: [this.phase(turn, "check")] },
      {
        after: 400,
        frames: [
          this.phase(turn, "query"),
          {
            type: "message",
            turn,
            payload: {
              id: queryId,
              kind: "query",
              turn,
              goal: "mortal(socrates)",
              answer: true,
            },
          },
        ],
      },
      {
        after: 300,
        frames: [
          {
            type: "message",
            turn,
            payload: {
              id: this.nextId("m"),
              kind: "query",
              turn,
              goal: "mortal(X)",
              answer: { bindings: [{ X: "socrates" }] },
            },
          },
        ],
      },
      { after: 250, frames: [this.phase(turn, "respond")] },
      ...this.tokenSteps(
        turn,
        replyId,
        "Yes — Socrates is mortal. That follows from human(socrates) and the rule mortal(X) :- human(X); the Prolog side proved mortal(socrates) directly.",
      ),
      {
        after: 120,
        frames: [
          {
            type: "assistant_message",
            turn,
            payload: {
              id: replyId,
              text: "Yes — Socrates is mortal. That follows from human(socrates) and the rule mortal(X) :- human(X); the Prolog side proved mortal(socrates) directly.",
              done: true,
            },
          },
          { type: "turn_done", turn, payload: {} },
        ],
      },
    ];
  }

  private contradictionScript(turn: string, text: string): Step[] {
    const userId = this.nextId("m");
    const clashId = this.nextId("m");
    const replyId = this.nextId("m");
    const offendingId = this.nextId("c");
    const offending: Clause = {
      id: offendingId,
      text: "fish(willy).",
      kind: "fact",
      turn,
    };
    const reply =
      "That conflicts with what you told me earlier: the constraint :- whale(A), fish(A). forbids anything being both, and willy is already a whale. I kept both clauses but flagged the clash.";
    return [
      { after: 60, frames: [{ type: "turn_started", turn, payload: {} }] },
      {
        after: 40,
        frames: [
          { type: "message", turn, payload: { id: userId, kind: "user", turn, text } },
        ],
      },
      { after: 200, frames: [this.phase(turn, "gate")] },
      {
        after: 300,
        frames: [
          {
            type: "gate_result",
            turn,
            payload: { new_facts: true, needs_query: false },
          },
        ],
      },
      {
        after: 200,
        frames: [
          this.phase(turn, "extract"),
          { type: "clauses_extracted", turn, payload: { clauses: [offending] } },
        ],
      },
      {
        after: 450,
        frames: [
          this.phase(turn, "assert"),
          {
            type: "kb_delta",
            turn,
            payload: {
              added: [
                {
                  id: this.nextId("c"),
                  text: "whale(willy).",
                  kind: "fact",
                  turn,
                },
                offending,
              ],
            },
          },
        ],
      },
      {
        after: 500,
        frames: [
          this.phase(turn, "check"),
          {
            type: "kb_delta",
            turn,
            payload: {
              flagged: [
                { id: offendingId, reason: "violates :- whale(A), fish(A)." },
              ],
            },
          },
          {
            type: "message",
            turn,
            payload: {
              id: clashId,
              kind: "contradiction",
              turn,
              constraint: ":- whale(A), fish(A).",
              witness: { A: "willy" },
              offending: "fish(willy).",
            },
          },
        ],
      },
      { after: 300, frames: [this.phase(turn, "respond")] },
      ...this.tokenSteps(turn, replyId, reply),
      {
        after: 120,
        frames: [
          {
            type: "assistant_message",
            turn,
            payload: { id: replyId, text: reply, done: true },
          },
          { type: "turn_done", turn, payload: {} },
        ],
      },
    ];
  }

  private tokenSteps(turn: string, id: string, text: string): Step[] {
    return text.split(/(?<=\s)/).map((token) => ({
      after: 28,
      frames: [
        { type: "assistant_token", turn, payload: { id, text: token } },
      ] as ServerFrameBody[],
    }));
  }

  private handleCancel(): void {
    const turn = this.activeTurn;
    this.clearTimers();
    if (!turn) return;
    this.activeTurn = null;
    this.emit({ type: "turn_done", turn, payload: {} });
  }

  /* ---------------------------------------------------------------- plumbing */

  private run(turn: string, steps: Step[]): void {
    let elapsed = 0;
    for (const step of steps) {
      elapsed += step.after;
      this.later(elapsed, () => {
        if (this.activeTurn !== turn) return; // cancelled
        for (const frame of step.frames) this.emit(frame);
        const last = steps[steps.length - 1];
        if (step === last) this.activeTurn = null;
      });
    }
  }

  private phase(turn: string, phase: TurnPhase): ServerFrameBody {
    return { type: "turn_phase", turn, payload: { phase } };
  }

  private emit(frame: ServerFrameBody): void {
    if (this.closed) return;
    if (frame.type === "kb_delta") this.applyDeltaLocally(frame.payload);
    if (frame.type === "message") this.transcript.push(frame.payload);
    this.seq += 1;
    const full = { v: PROTOCOL_VERSION, seq: this.seq, ts: Date.now(), ...frame };
    this.onmessage?.call(this, { data: JSON.stringify(full) });
  }

  private applyDeltaLocally(payload: {
    added?: Clause[];
    retracted?: string[];
  }): void {
    if (payload.added) {
      for (const clause of payload.added) {
        if (!this.clauses.some((c) => c.id === clause.id)) {
          this.clauses.push(clause);
        }
      }
    }
    if (payload.retracted) {
      const gone = new Set(payload.retracted);
      this.clauses = this.clauses.filter((c) => !gone.has(c.id));
    }
  }

  private nextId(prefix: string): string {
    this.ids += 1;
    return `${prefix}${100 + this.ids}`;
  }

  private later(ms: number, fn: () => void): void {
    const timer = setTimeout(() => {
      this.timers.delete(timer);
      if (!this.closed) fn();
    }, ms);
    this.timers.add(timer);
  }

  private clearTimers(): void {
    for (const timer of this.timers) clearTimeout(timer);
    this.timers.clear();
  }
}

export const mockSocketFactory = (): SocketLike => new MockSocket();
