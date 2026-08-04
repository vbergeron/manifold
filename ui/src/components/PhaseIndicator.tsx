import { TURN_PHASES } from "../protocol/types";
import type { TurnState } from "../state/store";

const PHASE_LABEL: Record<string, string> = {
  gate: "gate",
  extract: "extract",
  assert: "assert",
  check: "check",
  query: "query",
  respond: "respond",
};

export function PhaseIndicator({ turn }: { turn: TurnState | null }) {
  if (!turn?.active) return null;
  const currentIndex = turn.phase ? TURN_PHASES.indexOf(turn.phase) : -1;

  return (
    <div className="phases" role="status" aria-live="polite">
      <span className="phases__spinner" aria-hidden="true" />
      <ol className="phases__list">
        {TURN_PHASES.map((phase, index) => {
          const state =
            currentIndex < 0
              ? "idle"
              : index < currentIndex
                ? "done"
                : index === currentIndex
                  ? "active"
                  : "idle";
          return (
            <li key={phase} className={`phases__item phases__item--${state}`}>
              {PHASE_LABEL[phase]}
            </li>
          );
        })}
      </ol>
      {turn.gate && (
        <span className="phases__gate">
          {turn.gate.new_facts && <span className="tag tag--gate">new facts</span>}
          {turn.gate.needs_query && <span className="tag tag--gate">query</span>}
        </span>
      )}
    </div>
  );
}
