defmodule Manifold.Turn do
  @moduledoc """
  The turn loop: **gate → extract → assert → check → query → respond**, exactly
  as sealed in the README, emitted as the protocol's event stream.

  Runs in its own process (spawned and monitored by `Manifold.Conversation`), so:

    * the conversation GenServer stays responsive while the model generates —
      `kb_request` and `cancel_turn` are answered mid-turn;
    * cancelling is just killing this process;
    * a crash here is reported as `error {internal}` and cannot take the KB down.

  The three ordering rules the loop must not break:

    1. **Gate once, up front.** Abstention is a normal result, which is what lets
       the extraction grammar stay strict (`clause+`).
    2. **Assert before query.** Goals are generated only after assertion, so they
       see the clauses this very message contributed. Never parallelise these.
    3. **Contradiction overrides the gate.** The gate decided `needs_query?`
       before assertion ran, so it cannot foresee a violated constraint. If one
       fires we skip the query and steer `respond` at the conflict instead of
       re-gating.
  """
  require Logger

  alias Manifold.{Clause, Conversation, Event, Gate, Grammar, Prompt}
  alias Manifold.Llama.Client
  alias Manifold.Prolog.Answer

  @extract_opts [n_predict: 200, temperature: 0.2]
  @goals_opts [n_predict: 120, temperature: 0.1]
  @respond_opts [n_predict: 300, temperature: 0.7]

  @query_timeout_s 10
  # A question rarely needs more than one goal; the cap bounds a runaway model.
  @max_goals 3
  # How much dialogue the respond step sees. The KB is the memory; this is only
  # enough context to keep pronouns and tone coherent.
  @history 6

  @doc """
  Run one turn. Emits, in order:

      turn_started · message{user}
      turn_phase{gate}    · gate_result
      turn_phase{extract} · clauses_extracted        (only if new_facts)
      turn_phase{assert}  · kb_delta                 (only if clauses extracted)
      turn_phase{check}   · message{contradiction}*  (only if clauses asserted)
      turn_phase{query}   · message{query}*          (only if needs_query, no contradiction)
      turn_phase{respond} · assistant_token* · assistant_message
      turn_done

  Failures interleave as `error` events and never abort the turn: the loop always
  reaches `respond` and always closes with `turn_done`.
  """
  @spec run(pid(), String.t(), String.t(), pid() | nil) :: :ok
  def run(conv, turn, text, subscriber) do
    Event.emit(subscriber, :turn_started, turn, %{})
    Event.emit(subscriber, :message, turn, Conversation.add_message(conv, turn, :user, %{text: text}))

    gate = gate(turn, text, subscriber)
    added = if gate.new_facts, do: extract(conv, turn, gate.statements, subscriber), else: []
    violations = if added != [], do: check(conv, turn, added, subscriber), else: []

    {answers, unanswered} =
      if gate.needs_query and violations == [],
        do: query(conv, turn, gate.questions, subscriber),
        else: {[], []}

    evidence = %{
      clauses: Enum.map(added, & &1.text),
      violations: violations,
      answers: answers,
      unanswered: unanswered
    }

    respond(conv, turn, text, evidence, subscriber)
    Event.emit(subscriber, :turn_done, turn, %{})
    :ok
  end

  # --- phases ----------------------------------------------------------------

  defp gate(turn, text, subscriber) do
    Event.emit(subscriber, :turn_phase, turn, %{phase: "gate"})
    gate = Gate.classify(text)
    # The event carries only the two booleans the protocol defines; the sentence
    # split the gate also produces is internal routing, not UI state.
    Event.emit(subscriber, :gate_result, turn, Map.take(gate, [:new_facts, :needs_query]))
    gate
  end

  # Extract under the grammar, preview, then assert. Returns the clauses that
  # made it into the KB.
  defp extract(conv, turn, text, subscriber) do
    Event.emit(subscriber, :turn_phase, turn, %{phase: "extract"})
    prompt = Prompt.extract(text, Conversation.known_predicates(conv))

    with {:ok, output} <- generate(prompt, @extract_opts, turn, subscriber),
         [_ | _] = texts <- Clause.split(output) do
      clauses = Conversation.prepare_clauses(conv, turn, texts)
      Event.emit(subscriber, :clauses_extracted, turn, %{clauses: clauses})

      Event.emit(subscriber, :turn_phase, turn, %{phase: "assert"})
      %{added: added, flagged: flagged} = Conversation.commit_clauses(conv, clauses)
      Event.emit(subscriber, :kb_delta, turn, %{added: added, retracted: [], flagged: flagged})
      added
    else
      [] ->
        # The grammar guarantees valid syntax, so this is truncation or an empty
        # generation — the gate over-fired. Not fatal, just nothing learned.
        Event.error(subscriber, turn, "grammar_parse_failed", "no clause found in model output")
        []

      {:error, _reason} ->
        []
    end
  end

  # Run every integrity constraint; a provable body is a contradiction.
  defp check(conv, turn, added, subscriber) do
    Event.emit(subscriber, :turn_phase, turn, %{phase: "check"})

    Enum.map(Conversation.check_constraints(conv), fn v ->
      fields = %{
        constraint: v.constraint.text,
        witness: v.witness,
        offending: offending(added, v.constraint)
      }

      message = Conversation.add_message(conv, turn, :contradiction, fields)
      Event.emit(subscriber, :message, turn, message)
      fields
    end)
  end

  # Generate goals against the *post-assert* KB and run them under a timeout.
  defp query(conv, turn, text, subscriber) do
    Event.emit(subscriber, :turn_phase, turn, %{phase: "query"})
    known = Conversation.known_predicates(conv)

    # A knowledge base with no predicates cannot answer anything. Asking it anyway
    # costs a generation and yields a goal that `unknown = fail` answers `false` —
    # which `respond` is instructed to report as "no". That is how "how are you
    # today?" came back as "No". Produce no evidence instead, and the empty
    # evidence block tells `respond` to simply converse.
    if known == [] do
      Logger.debug("[turn] #{turn}: query skipped, knowledge base has no predicates")
      {[], [%{goal: nil, missing: []}]}
    else
      case generate(Prompt.goals(text, known), @goals_opts, turn, subscriber) do
        {:ok, output} ->
          output
          |> Clause.split()
          |> Enum.reject(&(Clause.kind(&1) == :constraint))
          |> Enum.take(@max_goals)
          |> Enum.map(&run_goal(conv, turn, &1, known, subscriber))
          |> Enum.reduce({[], []}, fn
            {:answer, fields}, {answers, unanswered} -> {answers ++ [fields], unanswered}
            {:unanswered, info}, {answers, unanswered} -> {answers, unanswered ++ [info]}
            :none, acc -> acc
          end)

        {:error, _reason} ->
          {[], []}
      end
    end
  end

  defp run_goal(conv, turn, clause, known, subscriber) do
    goal = Clause.body(clause)

    case Clause.signatures(clause) -- known do
      # The KB has never heard of this predicate, so `unknown = fail` will answer
      # `false` — a *vacuous* false, indistinguishable from a proved negative once
      # it reaches the evidence block. "Do you like cats?" becoming `likes(cats)`
      # is not a question the KB can answer, so it contributes no evidence rather
      # than a denial. Note the granularity: a *known* predicate applied to an
      # unknown term is still answered, so "is Zeus mortal?" is legitimately `false`
      # under the closed-world assumption.
      [_ | _] = unknown ->
        Logger.debug("[turn] #{turn}: dropped #{goal}, KB has no #{Enum.join(unknown, ", ")}")
        {:unanswered, %{goal: goal, missing: unknown}}

      [] ->
        case Conversation.query(conv, goal, @query_timeout_s) do
          {:ok, result} ->
            fields = %{goal: goal, answer: Answer.encode(result)}
            Event.emit(subscriber, :message, turn, Conversation.add_message(conv, turn, :query, fields))
            {:answer, fields}

          {:error, "time_limit_exceeded"} ->
            Event.error(subscriber, turn, "prolog_timeout", "#{goal} exceeded #{@query_timeout_s}s")
            :none

          {:error, reason} ->
            Event.error(subscriber, turn, "internal", "prolog error on #{goal}: #{inspect(reason)}")
            :none
        end
    end
  end

  # The one ungrammared step: prose, streamed token by token into a transcript
  # message that already has its id, so the UI can render the bubble immediately.
  defp respond(conv, turn, text, evidence, subscriber) do
    Event.emit(subscriber, :turn_phase, turn, %{phase: "respond"})
    %{id: id} = Conversation.begin_assistant(conv, turn)

    prompt =
      Prompt.respond(Map.merge(evidence, %{message: text, history: history(conv, id)}))

    emit = fn delta ->
      Conversation.append_assistant(conv, id, delta)
      Event.emit(subscriber, :assistant_token, turn, %{id: id, text: delta})
    end

    reply =
      case Client.stream(prompt, @respond_opts, emit) do
        {:ok, streamed} ->
          String.trim(streamed)

        {:error, reason} ->
          # No model, or it died mid-stream. Say so, but still close the bubble
          # with the evidence we do have — the Prolog half works without an LLM.
          Event.error(subscriber, turn, "llama_unavailable", inspect(reason))
          fallback = fallback(evidence)
          emit.(fallback)
          fallback
      end

    Conversation.finish_assistant(conv, id, reply)
    Event.emit(subscriber, :assistant_message, turn, %{id: id, text: reply, done: true})
  end

  # --- helpers ---------------------------------------------------------------

  defp generate(prompt, opts, turn, subscriber) do
    case Client.completion(prompt, Keyword.put(opts, :grammar, Grammar.prolog())) do
      {:ok, output} ->
        {:ok, output}

      {:error, reason} ->
        Event.error(subscriber, turn, "llama_unavailable", inspect(reason))
        {:error, reason}
    end
  end

  # Which clause from this turn tripped the constraint. There is no way to ask
  # Prolog "which clause made this provable", so we attribute it to the first
  # clause added this turn that shares a predicate with the constraint body —
  # right in the single-culprit case the UI cares about, `nil` when unsure.
  defp offending(added, constraint) do
    signatures = MapSet.new(Clause.signatures(constraint.text))

    Enum.find_value(added, fn clause ->
      if Enum.any?(Clause.signatures(clause.text), &MapSet.member?(signatures, &1)), do: clause.text
    end)
  end

  # The last few NL turns, excluding the assistant message we are about to fill.
  defp history(conv, current_id) do
    conv
    |> Conversation.transcript_snapshot()
    |> Enum.filter(&(&1.kind in ["user", "assistant"] and &1.id != current_id))
    |> Enum.take(-@history)
  end

  defp fallback(%{violations: [violation | _]}) do
    "That contradicts #{violation.constraint} — which of the two should I keep?"
  end

  defp fallback(evidence) do
    [
      case evidence.answers do
        [] -> nil
        list -> "From the knowledge base: " <> Enum.map_join(list, "; ", &"#{&1.goal} is #{inspect(&1.answer)}")
      end,
      case evidence.unanswered do
        [] -> nil
        _ -> "I have nothing stored that bears on that."
      end,
      case evidence.clauses do
        [] -> nil
        list -> "Learned: " <> Enum.join(list, " ")
      end
    ]
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> "(no language model available)"
      parts -> Enum.join(parts, " ")
    end
  end
end
