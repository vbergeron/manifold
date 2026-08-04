import { useEffect, useRef } from "react";
import type { MessageView, TurnState } from "../state/store";
import { Composer } from "./Composer";
import { MessageItem } from "./MessageView";
import { PhaseIndicator } from "./PhaseIndicator";

interface Props {
  messages: MessageView[];
  turn: TurnState | null;
  connected: boolean;
  onSend: (text: string) => boolean;
  onCancel: () => void;
}

const PIN_THRESHOLD_PX = 120;

export function ChatPanel({
  messages,
  turn,
  connected,
  onSend,
  onCancel,
}: Props) {
  const scrollRef = useRef<HTMLDivElement>(null);
  const pinnedRef = useRef(true);

  // Follow the stream only while the reader is already near the bottom.
  const tail = messages[messages.length - 1];
  const tailLength =
    tail && "text" in tail.message ? tail.message.text.length : 0;
  useEffect(() => {
    const node = scrollRef.current;
    if (!node || !pinnedRef.current) return;
    node.scrollTop = node.scrollHeight;
  }, [messages.length, tailLength, turn?.phase]);

  return (
    <section className="panel panel--chat" aria-label="Conversation">
      <header className="panel__head">
        <div>
          <h2 className="panel__title">Conversation</h2>
          <p className="panel__sub">
            {messages.length} entr{messages.length === 1 ? "y" : "ies"} · queries
            and contradictions are part of the record
          </p>
        </div>
      </header>

      <div
        className="panel__body panel__body--chat"
        ref={scrollRef}
        onScroll={(event) => {
          const node = event.currentTarget;
          pinnedRef.current =
            node.scrollHeight - node.scrollTop - node.clientHeight <
            PIN_THRESHOLD_PX;
        }}
      >
        {messages.length === 0 ? (
          <p className="empty">
            Nothing yet. Say something like <em>“Socrates is a human. Is he
            mortal?”</em> — the left panel will fill in as the claim is distilled
            into Prolog.
          </p>
        ) : (
          messages.map((view) => <MessageItem key={view.message.id} view={view} />)
        )}
      </div>

      <footer className="panel__foot">
        <PhaseIndicator turn={turn} />
        <Composer
          connected={connected}
          turnActive={Boolean(turn?.active)}
          onSend={onSend}
          onCancel={onCancel}
        />
      </footer>
    </section>
  );
}
