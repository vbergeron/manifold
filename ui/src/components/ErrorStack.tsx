import type { ErrorEntry } from "../state/store";

interface Props {
  errors: ErrorEntry[];
  onDismiss: (id: number) => void;
}

export function ErrorStack({ errors, onDismiss }: Props) {
  if (errors.length === 0) return null;
  return (
    <div className="errors">
      {errors.map((error) => (
        <div className="errors__item" key={error.id} role="alert">
          <code className="errors__code">{error.code}</code>
          <span className="errors__msg">{error.message}</span>
          <button
            type="button"
            className="errors__close"
            aria-label="Dismiss"
            onClick={() => onDismiss(error.id)}
          >
            ×
          </button>
        </div>
      ))}
    </div>
  );
}
