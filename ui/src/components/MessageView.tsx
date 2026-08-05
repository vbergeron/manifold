import {
  answerIsBindings,
  isQuestionMode,
  type TranscriptMessage,
} from "../protocol/types";
import { stringifyValue, type MessageView as MessageViewModel } from "../state/store";

export function MessageItem({ view }: { view: MessageViewModel }) {
  const { message, streaming } = view;
  switch (message.kind) {
    case "user":
    case "assistant":
      return <Bubble message={message} streaming={streaming} />;
    case "query":
      return <QueryChip message={message} />;
    case "contradiction":
      return <ContradictionCard message={message} />;
  }
}

function Bubble({
  message,
  streaming,
}: {
  message: Extract<TranscriptMessage, { kind: "user" | "assistant" }>;
  streaming: boolean;
}) {
  const question = message.kind === "user" && isQuestionMode(message.text);

  return (
    <div className={`row row--${message.kind}`}>
      <div className={`bubble bubble--${message.kind}${question ? " bubble--question" : ""}`}>
        <span className="bubble__who">
          {message.kind === "user" ? "You" : "Manifold"}
        </span>
        <p className="bubble__text">
          {question ? <QuestionText text={message.text} /> : message.text}
          {streaming && <span className="caret" aria-hidden="true" />}
        </p>
      </div>
    </div>
  );
}

/**
 * A question-mode message with its opening `?` (and an optional `-`, so
 * `?- goal.` highlights the same way `? goal.` does) picked out — the visual
 * cue that this text went straight to Prolog rather than through the model.
 */
function QuestionText({ text }: { text: string }) {
  const match = /^(\s*)(\?+-?)([\s\S]*)$/.exec(text);
  if (!match) return <>{text}</>;
  const [, lead, marker, rest] = match;

  return (
    <>
      {lead}
      <mark className="qmark">{marker}</mark>
      {rest}
    </>
  );
}

/** A Prolog goal that was run — deliberately not a chat bubble. */
function QueryChip({
  message,
}: {
  message: Extract<TranscriptMessage, { kind: "query" }>;
}) {
  const { answer } = message;
  const verdict = answer === true ? "true" : answer === false ? "false" : "bindings";

  return (
    <div className="row row--aside">
      <div className={`query query--${verdict}`}>
        <span className="query__label">query</span>
        <code className="query__goal">?- {message.goal}</code>
        <span className="query__arrow" aria-hidden="true">
          →
        </span>
        {answerIsBindings(answer) ? (
          <span className="query__answer">
            {answer.bindings.length === 0 ? (
              <em className="query__none">no solutions</em>
            ) : (
              answer.bindings.map((binding, index) => (
                <code className="binding" key={index}>
                  {Object.entries(binding)
                    .map(([key, value]) => `${key} = ${stringifyValue(value)}`)
                    .join(", ")}
                </code>
              ))
            )}
          </span>
        ) : (
          <span className={`verdict verdict--${verdict}`}>{verdict}</span>
        )}
      </div>
    </div>
  );
}

/** A violated integrity constraint — the loudest thing in the transcript. */
function ContradictionCard({
  message,
}: {
  message: Extract<TranscriptMessage, { kind: "contradiction" }>;
}) {
  const witness = Object.entries(message.witness ?? {});

  return (
    <div className="row row--aside">
      <div className="clash" role="alert">
        <div className="clash__head">
          <span className="clash__icon" aria-hidden="true">
            ⚠
          </span>
          <span className="clash__title">Contradiction</span>
          <span className="clash__sub">an integrity constraint is provable</span>
        </div>
        <dl className="clash__grid">
          <dt>constraint</dt>
          <dd>
            <code>{message.constraint}</code>
          </dd>
          {message.offending && (
            <>
              <dt>offending</dt>
              <dd>
                <code>{message.offending}</code>
              </dd>
            </>
          )}
          {witness.length > 0 && (
            <>
              <dt>witness</dt>
              <dd>
                {witness.map(([key, value]) => (
                  <code className="binding" key={key}>
                    {key} = {stringifyValue(value)}
                  </code>
                ))}
              </dd>
            </>
          )}
        </dl>
      </div>
    </div>
  );
}
