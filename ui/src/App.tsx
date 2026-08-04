import { useMemo } from "react";
import { USE_MOCK, WS_URL } from "./config";
import { mockSocketFactory } from "./mock/mockSocket";
import { ChatPanel } from "./components/ChatPanel";
import { ConnectionBadge } from "./components/ConnectionBadge";
import { ErrorStack } from "./components/ErrorStack";
import { KbPanel } from "./components/KbPanel";
import { selectClauses, selectMessages } from "./state/store";
import { useManifold } from "./state/useManifold";
import { useTheme } from "./useTheme";

const THEME_GLYPH = { system: "◐", light: "☀", dark: "☾" } as const;

export default function App() {
  const factory = USE_MOCK ? mockSocketFactory : undefined;
  const manifold = useManifold(WS_URL, factory);
  const { state } = manifold;
  const [theme, cycleTheme] = useTheme();

  const clauses = useMemo(() => selectClauses(state), [state]);
  const messages = useMemo(() => selectMessages(state), [state]);

  return (
    <div className="app">
      <header className="topbar">
        <div className="brand">
          <span className="brand__mark" aria-hidden="true" />
          <span className="brand__name">Manifold</span>
          <span className="brand__tag">every conversation, doubled in Prolog</span>
        </div>
        <div className="topbar__right">
          {state.sidecars && (
            <span className="sidecars">
              <span
                className={`sidecar sidecar--${state.sidecars.llama ? "up" : "down"}`}
              >
                llama
              </span>
              <span
                className={`sidecar sidecar--${state.sidecars.prolog ? "up" : "down"}`}
              >
                prolog
              </span>
            </span>
          )}
          {state.conversationId && (
            <code className="conv-id" title="conversation id">
              {state.conversationId}
            </code>
          )}
          <ConnectionBadge
            status={state.status}
            mock={USE_MOCK}
            onRetry={manifold.reconnectNow}
          />
          <button
            type="button"
            className="btn btn--ghost btn--sm"
            onClick={cycleTheme}
            title={`Theme: ${theme}`}
            aria-label={`Theme: ${theme}`}
          >
            {THEME_GLYPH[theme]}
          </button>
        </div>
      </header>

      <main className="panels">
        <KbPanel clauses={clauses} onRefresh={manifold.requestKb} />
        <ChatPanel
          messages={messages}
          turn={state.turn}
          connected={state.status === "open"}
          onSend={manifold.sendMessage}
          onCancel={manifold.cancelTurn}
        />
      </main>

      <ErrorStack errors={state.errors} onDismiss={manifold.dismissError} />
    </div>
  );
}
