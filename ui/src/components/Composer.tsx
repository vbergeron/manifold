import { useEffect, useRef, useState } from "react";
import { isQuestionMode } from "../protocol/types";

interface Props {
  connected: boolean;
  turnActive: boolean;
  onSend: (text: string) => boolean;
  onCancel: () => void;
}

const MAX_TEXTAREA_PX = 168;

export function Composer({ connected, turnActive, onSend, onCancel }: Props) {
  const [text, setText] = useState("");
  const areaRef = useRef<HTMLTextAreaElement>(null);

  // Grow with content, up to a cap; the transcript keeps the rest of the height.
  useEffect(() => {
    const area = areaRef.current;
    if (!area) return;
    area.style.height = "auto";
    area.style.height = `${Math.min(area.scrollHeight, MAX_TEXTAREA_PX)}px`;
  }, [text]);

  const canSend = connected && !turnActive && text.trim().length > 0;
  const questionMode = isQuestionMode(text);

  function submit() {
    if (!canSend) return;
    if (onSend(text.trim())) setText("");
  }

  return (
    <form
      className="composer"
      onSubmit={(event) => {
        event.preventDefault();
        submit();
      }}
    >
      <div className={`composer__field${questionMode ? " composer__field--question" : ""}`}>
        {questionMode && (
          <mark className="composer__qmark" aria-hidden="true">
            ?
          </mark>
        )}
        <textarea
          ref={areaRef}
          className="composer__input"
          rows={1}
          value={text}
          placeholder={
            connected
              ? "State a fact, a rule, or ask a question… (start with ? for a raw Prolog query)"
              : "Waiting for the server…"
          }
          disabled={!connected}
          onChange={(event) => setText(event.target.value)}
          onKeyDown={(event) => {
            if (event.key === "Enter" && !event.shiftKey) {
              event.preventDefault();
              submit();
            }
          }}
        />
      </div>
      <div className="composer__actions">
        {turnActive && (
          <button type="button" className="btn btn--danger" onClick={onCancel}>
            Cancel
          </button>
        )}
        <button type="submit" className="btn btn--primary" disabled={!canSend}>
          Send
        </button>
      </div>
      <p className="composer__hint">
        Enter to send · Shift+Enter for a newline
        {questionMode && " · sent straight to Prolog as a query"}
        {turnActive && " · a turn is in flight"}
      </p>
    </form>
  );
}
