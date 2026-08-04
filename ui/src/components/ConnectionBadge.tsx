import type { ConnectionStatus } from "../protocol/client";

const LABELS: Record<ConnectionStatus, string> = {
  connecting: "Connecting",
  open: "Live",
  reconnecting: "Reconnecting",
  closed: "Disconnected",
};

interface Props {
  status: ConnectionStatus;
  mock: boolean;
  onRetry: () => void;
}

export function ConnectionBadge({ status, mock, onRetry }: Props) {
  return (
    <div className="conn">
      {mock && <span className="conn__mock">mock feed</span>}
      <span className={`conn__badge conn__badge--${status}`}>
        <span className="conn__dot" />
        {LABELS[status]}
      </span>
      {status !== "open" && (
        <button type="button" className="btn btn--ghost btn--sm" onClick={onRetry}>
          Retry
        </button>
      )}
    </div>
  );
}
