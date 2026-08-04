import {
  PROTOCOL_VERSION,
  parseServerFrame,
  type OutboundFrame,
  type ServerFrame,
} from "./types";

export type ConnectionStatus =
  | "connecting"
  | "open"
  | "reconnecting"
  | "closed";

/**
 * The slice of `WebSocket` the client actually uses. Lets the dev-only mock
 * feed travel the exact same code path as a real socket.
 */
export interface SocketLike {
  send(data: string): void;
  close(code?: number, reason?: string): void;
  onopen: ((this: unknown, ev: unknown) => void) | null;
  onmessage: ((this: unknown, ev: { data: unknown }) => void) | null;
  onclose: ((this: unknown, ev: unknown) => void) | null;
  onerror: ((this: unknown, ev: unknown) => void) | null;
}

export type SocketFactory = (url: string) => SocketLike;

export interface ManifoldClientOptions {
  url: string;
  /** Called for every accepted server frame, in arrival order. */
  onFrame: (frame: ServerFrame) => void;
  onStatus: (status: ConnectionStatus) => void;
  /** Defaults to the browser `WebSocket`. */
  socketFactory?: SocketFactory;
}

const BASE_BACKOFF_MS = 500;
const MAX_BACKOFF_MS = 15_000;

/**
 * One connection ⇄ one conversation.
 *
 * Owns the socket lifecycle: connect, send `open` on every (re)connect,
 * auto-reconnect with exponential backoff + jitter. It is intentionally
 * stateless about panel contents — it only remembers the `conversation_id`
 * handed back by `session`, so a reconnect re-attaches instead of creating a
 * fresh conversation.
 */
export class ManifoldClient {
  private readonly options: ManifoldClientOptions;
  private readonly socketFactory: SocketFactory;
  private socket: SocketLike | null = null;
  private conversationId: string | null = null;
  private attempt = 0;
  private reconnectTimer: ReturnType<typeof setTimeout> | null = null;
  private disposed = false;
  private connected = false;

  constructor(options: ManifoldClientOptions) {
    this.options = options;
    this.socketFactory = options.socketFactory ?? defaultSocketFactory;
  }

  connect(): void {
    if (this.disposed || this.socket) return;
    this.clearReconnectTimer();
    this.options.onStatus(this.attempt === 0 ? "connecting" : "reconnecting");

    let socket: SocketLike;
    try {
      socket = this.socketFactory(this.options.url);
    } catch {
      this.scheduleReconnect();
      return;
    }
    this.socket = socket;

    socket.onopen = () => {
      if (this.socket !== socket) return;
      this.attempt = 0;
      this.connected = true;
      this.options.onStatus("open");
      // Re-attach to the same conversation; null on the very first connect.
      this.send({
        type: "open",
        turn: null,
        payload: { conversation_id: this.conversationId },
      });
    };

    socket.onmessage = (event) => {
      if (this.socket !== socket) return;
      if (typeof event.data !== "string") return;
      const frame = parseServerFrame(event.data);
      if (!frame) return;
      if (frame.type === "session") {
        this.conversationId = frame.payload.conversation_id;
      }
      this.options.onFrame(frame);
    };

    socket.onerror = () => {
      // `onclose` always follows; reconnect is driven from there.
    };

    socket.onclose = () => {
      if (this.socket !== socket) return;
      this.socket = null;
      this.connected = false;
      if (this.disposed) {
        this.options.onStatus("closed");
        return;
      }
      this.scheduleReconnect();
    };
  }

  /** Frames sent while the socket is down are dropped, not queued. */
  send(frame: OutboundFrame & { ts?: number }): boolean {
    if (!this.socket || !this.connected) return false;
    const full = {
      v: PROTOCOL_VERSION,
      ts: frame.ts ?? Date.now(),
      ...frame,
    };
    try {
      this.socket.send(JSON.stringify(full));
      return true;
    } catch {
      return false;
    }
  }

  sendUserMessage(turn: string, text: string): boolean {
    return this.send({ type: "user_message", turn, payload: { text } });
  }

  cancelTurn(turn: string): boolean {
    return this.send({ type: "cancel_turn", turn, payload: {} });
  }

  requestKb(): boolean {
    return this.send({ type: "kb_request", turn: null, payload: {} });
  }

  /** Drop the current socket and reconnect immediately (manual retry). */
  reconnectNow(): void {
    this.attempt = 0;
    this.clearReconnectTimer();
    const socket = this.socket;
    this.socket = null;
    this.connected = false;
    socket?.close(1000, "client reconnect");
    this.connect();
  }

  dispose(): void {
    this.disposed = true;
    this.clearReconnectTimer();
    const socket = this.socket;
    this.socket = null;
    this.connected = false;
    socket?.close(1000, "client disposed");
    // Detaching the socket above makes its `onclose` a no-op, so report the
    // final status here rather than waiting for an event that never lands.
    this.options.onStatus("closed");
  }

  private scheduleReconnect(): void {
    this.attempt += 1;
    this.options.onStatus("reconnecting");
    const backoff = Math.min(
      MAX_BACKOFF_MS,
      BASE_BACKOFF_MS * 2 ** (this.attempt - 1),
    );
    const delay = backoff * (0.75 + Math.random() * 0.5);
    this.reconnectTimer = setTimeout(() => {
      this.reconnectTimer = null;
      this.connect();
    }, delay);
  }

  private clearReconnectTimer(): void {
    if (this.reconnectTimer !== null) {
      clearTimeout(this.reconnectTimer);
      this.reconnectTimer = null;
    }
  }
}

function defaultSocketFactory(url: string): SocketLike {
  return new WebSocket(url) as unknown as SocketLike;
}
