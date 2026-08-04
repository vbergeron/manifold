import type { ClauseKind } from "../protocol/types";
import type { ClauseView } from "../state/store";

const GROUPS: { kind: ClauseKind; title: string; hint: string }[] = [
  { kind: "fact", title: "Facts", hint: "asserted ground truth" },
  { kind: "rule", title: "Rules", hint: "head :- body" },
  { kind: "constraint", title: "Constraints", hint: ":- body must never hold" },
];

interface Props {
  clauses: ClauseView[];
  onRefresh: () => void;
}

export function KbPanel({ clauses, onRefresh }: Props) {
  const flagged = clauses.filter((c) => c.flaggedReason).length;

  return (
    <section className="panel panel--kb" aria-label="Knowledge base">
      <header className="panel__head">
        <div>
          <h2 className="panel__title">Knowledge Base</h2>
          <p className="panel__sub">
            {clauses.length} clause{clauses.length === 1 ? "" : "s"}
            {flagged > 0 && (
              <>
                {" · "}
                <span className="panel__sub-warn">{flagged} flagged</span>
              </>
            )}
            {" · read-only"}
          </p>
        </div>
        <button
          type="button"
          className="btn btn--ghost btn--sm"
          onClick={onRefresh}
          title="Ask the server to re-send the KB snapshot"
        >
          Refresh
        </button>
      </header>

      <div className="panel__body">
        {clauses.length === 0 ? (
          <p className="empty">
            The knowledge base is empty. State a fact or a rule in the chat and
            it will be distilled into Prolog here.
          </p>
        ) : (
          GROUPS.map(({ kind, title, hint }) => {
            const group = clauses.filter((c) => c.kind === kind);
            if (group.length === 0) return null;
            return (
              <div className="group" key={kind}>
                <div className="group__head">
                  <span className={`kind kind--${kind}`}>{title}</span>
                  <span className="group__count">{group.length}</span>
                  <span className="group__hint">{hint}</span>
                </div>
                <ul className="clauses">
                  {group.map((clause) => (
                    <ClauseRow key={clause.id} clause={clause} />
                  ))}
                </ul>
              </div>
            );
          })
        )}
      </div>
    </section>
  );
}

function ClauseRow({ clause }: { clause: ClauseView }) {
  const classes = [
    "clause",
    `clause--${clause.kind}`,
    clause.isNew ? "clause--new" : "",
    clause.flaggedReason ? "clause--flagged" : "",
    clause.pending ? "clause--pending" : "",
  ]
    .filter(Boolean)
    .join(" ");

  return (
    <li className={classes}>
      <code className="clause__text">{clause.text}</code>
      <div className="clause__meta">
        <span className="clause__id">{clause.id}</span>
        {clause.turn && <span className="clause__turn">{clause.turn}</span>}
        {clause.pending && <span className="tag tag--pending">extracted</span>}
        {clause.flaggedReason && (
          <span className="tag tag--flagged" title={clause.flaggedReason}>
            contradiction
          </span>
        )}
      </div>
      {clause.flaggedReason && (
        <p className="clause__reason">{clause.flaggedReason}</p>
      )}
    </li>
  );
}
