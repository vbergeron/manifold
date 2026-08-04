import { useCallback, useEffect, useMemo, useReducer, useRef } from "react";
import { ManifoldClient, type SocketFactory } from "../protocol/client";
import { mintTurnId } from "../protocol/types";
import { initialState, reducer, type State } from "./store";

const NEW_CLAUSE_HIGHLIGHT_MS = 2600;

export interface ManifoldApi {
  state: State;
  /** Returns false if the socket is down (message not sent). */
  sendMessage: (text: string) => boolean;
  cancelTurn: () => void;
  requestKb: () => void;
  reconnectNow: () => void;
  dismissError: (id: number) => void;
}

export function useManifold(
  url: string,
  socketFactory?: SocketFactory,
): ManifoldApi {
  const [state, dispatch] = useReducer(reducer, initialState);
  const clientRef = useRef<ManifoldClient | null>(null);

  useEffect(() => {
    const client = new ManifoldClient({
      url,
      onFrame: (frame) => dispatch({ type: "frame", frame }),
      onStatus: (status) => dispatch({ type: "status", status }),
      ...(socketFactory ? { socketFactory } : {}),
    });
    clientRef.current = client;
    client.connect();
    return () => {
      client.dispose();
      clientRef.current = null;
    };
  }, [url, socketFactory]);

  // Retire the "just added" highlight a beat after the clause lands.
  const highlighted = state.clauseOrder.filter((id) => state.clauses[id]?.isNew);
  const highlightKey = highlighted.join("|");
  useEffect(() => {
    if (!highlightKey) return;
    const ids = highlightKey.split("|");
    const timer = setTimeout(
      () => dispatch({ type: "clear_new", ids }),
      NEW_CLAUSE_HIGHLIGHT_MS,
    );
    return () => clearTimeout(timer);
  }, [highlightKey]);

  const sendMessage = useCallback((text: string) => {
    const client = clientRef.current;
    if (!client) return false;
    const turn = mintTurnId();
    const sent = client.sendUserMessage(turn, text);
    if (sent) dispatch({ type: "local_turn", turn });
    return sent;
  }, []);

  const turnId = state.turn?.active ? state.turn.id : null;
  const cancelTurn = useCallback(() => {
    if (turnId) clientRef.current?.cancelTurn(turnId);
  }, [turnId]);

  const requestKb = useCallback(() => {
    clientRef.current?.requestKb();
  }, []);

  const reconnectNow = useCallback(() => {
    clientRef.current?.reconnectNow();
  }, []);

  const dismissError = useCallback((id: number) => {
    dispatch({ type: "dismiss_error", id });
  }, []);

  return useMemo(
    () => ({
      state,
      sendMessage,
      cancelTurn,
      requestKb,
      reconnectNow,
      dismissError,
    }),
    [state, sendMessage, cancelTurn, requestKb, reconnectNow, dismissError],
  );
}
