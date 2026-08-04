defmodule Manifold.Conversation do
  @moduledoc """
  One conversation, *doubled*: a typed natural-language transcript plus a private
  Prolog knowledge base held open over a dedicated MQI connection.

  This is the unit that realises manifold's thesis, and it is the single source of
  truth for both UI panels (`docs/PROTOCOL.md`):

    * **left** — `kb_snapshot/1`: every clause with a stable server-assigned `id`,
      a `kind` (`fact` | `rule` | `constraint`) and the `turn` that produced it.
      Append-only in v1: nothing is ever retracted.
    * **right** — `transcript_snapshot/1`: messages tagged `user` | `assistant` |
      `query` | `contradiction`.

  Because the server owns all of it, a reconnecting client needs no replay
  buffer — it re-`open`s and takes both snapshots.

  `run_turn/4` executes the sealed turn loop. The loop itself runs in a *separate,
  monitored process* (`Manifold.Turn`), for two reasons: this GenServer stays
  responsive to `kb_request` and `cancel_turn` while the model generates, and a
  cancel is then just killing that process. The KB is only ever touched through
  calls back into here, so it stays serialised.

  Started under `Manifold.Conversation.Supervisor` via `Manifold.start_conversation/1`
  and, when given an `:id`, registered in `Manifold.Conversation.Registry` so a
  reconnecting socket can find it again.
  """
  use GenServer, restart: :transient
  require Logger

  alias Manifold.{Clause, Event, Store, Turn}
  alias Manifold.Prolog.{Answer, MQI}

  @registry Manifold.Conversation.Registry

  # A constraint body is a goal like any other: it needs a kill switch.
  @check_timeout_s 5

  @type clause :: %{id: String.t(), text: String.t(), kind: String.t(), turn: String.t() | nil}
  @type message :: %{id: String.t(), kind: String.t(), turn: String.t() | nil}

  # --- client API ------------------------------------------------------------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: name_for(opts))
  end

  @doc "A fresh conversation id, minted when the client opens without one."
  @spec new_id() :: String.t()
  def new_id, do: "conv_" <> Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)

  @doc "`:via` tuple for the conversation registered under `id`."
  def via(id), do: {:via, Registry, {@registry, id}}

  @doc "Assert one clause or a list of clauses (Prolog source, trailing `.` optional)."
  @spec assert(pid(), String.t() | [String.t()]) :: [term()]
  def assert(pid, clauses), do: GenServer.call(pid, {:assert, List.wrap(clauses), nil})

  @doc "Query a goal against this conversation's KB (timeout in seconds)."
  @spec query(pid(), String.t(), integer()) :: {:ok, term()} | {:error, term()}
  def query(pid, goal, timeout_s \\ 10),
    do: GenServer.call(pid, {:query, goal, timeout_s}, 60_000)

  @doc "Number of clauses asserted so far this conversation."
  def kb_size(pid), do: GenServer.call(pid, :kb_size)

  @doc "Every clause in the KB, oldest first — the `kb_snapshot` payload."
  @spec kb_snapshot(pid()) :: [clause()]
  def kb_snapshot(pid), do: GenServer.call(pid, :kb_snapshot)

  @doc "Every transcript message, oldest first — the `transcript_snapshot` payload."
  @spec transcript_snapshot(pid()) :: [message()]
  def transcript_snapshot(pid), do: GenServer.call(pid, :transcript_snapshot)

  @doc "`name/arity` of everything the KB knows about, for the next prompt's vocabulary."
  @spec known_predicates(pid()) :: [String.t()]
  def known_predicates(pid), do: GenServer.call(pid, :known_predicates)

  @doc """
  Reserve ids for `texts` without asserting them — the `clauses_extracted`
  preview. Ids are burned whether or not the follow-up `commit_clauses/2`
  succeeds, which is what makes them stable for the UI.
  """
  @spec prepare_clauses(pid(), String.t() | nil, [String.t()]) :: [clause()]
  def prepare_clauses(pid, turn, texts), do: GenServer.call(pid, {:prepare_clauses, turn, texts})

  @doc """
  Assert prepared clauses. Returns the `kb_delta` payload: `added` are in the KB,
  `flagged` failed to assert (with the Prolog reason) and are *not* recorded.
  """
  @spec commit_clauses(pid(), [clause()]) :: %{added: [clause()], flagged: [map()]}
  def commit_clauses(pid, clauses), do: GenServer.call(pid, {:commit_clauses, clauses}, 60_000)

  @doc """
  Run every integrity constraint in the KB and return the violated ones as
  `%{constraint: clause, witness: map | nil}`.

  A constraint is `:- Body` meaning *"Body must never be derivable"*, so a
  *provable* body is a contradiction. Undefined predicates are not violations —
  `unknown = fail` (set at init) turns them into plain failure instead of an
  `existence_error`. A constraint that times out is logged and treated as
  non-violated: we never manufacture a contradiction we could not prove.
  """
  @spec check_constraints(pid(), pos_integer()) :: [%{constraint: clause(), witness: map() | nil}]
  def check_constraints(pid, timeout_s \\ @check_timeout_s),
    do: GenServer.call(pid, {:check_constraints, timeout_s}, 60_000)

  @doc "Append a transcript message of `kind` (`:user` | `:query` | `:contradiction`)."
  @spec add_message(pid(), String.t() | nil, atom(), map()) :: message()
  def add_message(pid, turn, kind, fields), do: GenServer.call(pid, {:add_message, turn, kind, fields})

  @doc "Open an empty `assistant` message so tokens have an `id` to stream into."
  @spec begin_assistant(pid(), String.t() | nil) :: message()
  def begin_assistant(pid, turn), do: GenServer.call(pid, {:add_message, turn, :assistant, %{text: ""}})

  @doc """
  Append a streamed token to an open assistant message. A cast: token rate must
  not be gated on the KB, and a lost token only costs snapshot fidelity for a
  client that reconnects mid-stream.
  """
  @spec append_assistant(pid(), String.t(), String.t()) :: :ok
  def append_assistant(pid, id, delta), do: GenServer.cast(pid, {:append_assistant, id, delta})

  @doc "Close an assistant message with its final text."
  @spec finish_assistant(pid(), String.t(), String.t()) :: message()
  def finish_assistant(pid, id, text), do: GenServer.call(pid, {:finish_assistant, id, text})

  @doc """
  Start the turn loop for `text` under turn id `turn`, streaming protocol events
  to `subscriber` as `{:manifold_event, envelope}`. One turn at a time per
  conversation.
  """
  @spec run_turn(pid(), String.t(), String.t(), pid() | nil) :: :ok | {:error, :turn_in_flight}
  def run_turn(pid, turn, text, subscriber \\ nil),
    do: GenServer.call(pid, {:run_turn, turn, text, subscriber})

  @doc """
  Abort the in-flight turn. Clauses already asserted stay (the KB is append-only
  in v1); the subscriber still gets a `turn_done` so the turn closes cleanly.
  """
  @spec cancel_turn(pid()) :: :ok
  def cancel_turn(pid), do: GenServer.call(pid, :cancel_turn)

  @doc "Id of the turn currently running, or `nil`."
  @spec current_turn(pid()) :: String.t() | nil
  def current_turn(pid), do: GenServer.call(pid, :current_turn)

  # --- server ----------------------------------------------------------------

  @impl true
  def init(opts) do
    case MQI.connect() do
      {:ok, conn} ->
        # Integrity constraints mention predicates that may not exist yet;
        # without this an undefined predicate throws existence_error instead of
        # failing, and every check would look like an error rather than "no
        # violation". Set once, for the life of this engine.
        {:ok, _} = MQI.run(conn, "set_prolog_flag(unknown, fail)")

        state = %{
          id: opts[:id],
          conn: conn,
          store: Store.open(opts[:id]),
          clauses: [],
          transcript: [],
          next_clause: 1,
          next_message: 1,
          turn: nil
        }

        {:ok, rehydrate(state)}

      {:error, reason} ->
        {:stop, {:mqi_connect_failed, reason}}
    end
  end

  # Replay the durable log into both halves of the conversation. Clauses go through
  # `insert_clauses/2` — the very same path a live turn uses — so there is exactly
  # one way a clause reaches Prolog, and a replayed KB cannot diverge from a live
  # one. Note what is *not* called here: `persist/2`. Replaying must not re-append
  # what it just read.
  defp rehydrate(s) do
    events = Store.replay(s.store)

    s =
      Enum.reduce(events, s, fn
        {:clauses, clauses}, acc ->
          {_delta, acc} = insert_clauses(acc, clauses)
          acc

        {:message, message}, acc ->
          %{acc | transcript: acc.transcript ++ [message]}
      end)

    if events != [] do
      Logger.info("[conversation] #{s.id}: replayed #{length(s.clauses)} clauses, #{length(s.transcript)} messages")
    end

    restore_counters(s)
  end

  # Counters are derived rather than stored, so the log holds only domain events.
  # An id burned on a clause that was then rejected is reused after a restart,
  # which is harmless: a reconnecting client re-takes both snapshots.
  defp restore_counters(s) do
    %{
      s
      | next_clause: 1 + highest(s.clauses, "c"),
        next_message: 1 + highest(s.transcript, "m")
    }
  end

  defp highest(records, prefix) do
    records
    |> Enum.map(fn %{id: id} ->
      case Integer.parse(String.trim_leading(id, prefix)) do
        {n, ""} -> n
        _ -> 0
      end
    end)
    |> Enum.max(fn -> 0 end)
  end

  @impl true
  def handle_call({:assert, texts, turn}, _from, s) do
    {clauses, s} = mint_clauses(s, turn, texts)
    {%{added: added, flagged: flagged}, s} = insert_clauses(s, clauses)
    persist(s, [{:clauses, added}])

    # Preserve the legacy shape: one `:ok` / `{:error, reason}` per input clause.
    reasons = Map.new(flagged, &{&1.id, &1.reason})
    results = Enum.map(clauses, fn c -> if r = reasons[c.id], do: {:error, r}, else: :ok end)
    {:reply, results, s}
  end

  def handle_call({:query, goal, timeout_s}, _from, s) do
    {:reply, MQI.run(s.conn, goal, timeout_s), s}
  end

  def handle_call(:kb_size, _from, s), do: {:reply, length(s.clauses), s}
  def handle_call(:kb_snapshot, _from, s), do: {:reply, s.clauses, s}
  def handle_call(:transcript_snapshot, _from, s), do: {:reply, s.transcript, s}
  def handle_call(:known_predicates, _from, s), do: {:reply, predicates(s.clauses), s}
  def handle_call(:current_turn, _from, s), do: {:reply, s.turn && s.turn.id, s}

  def handle_call({:prepare_clauses, turn, texts}, _from, s) do
    {clauses, s} = mint_clauses(s, turn, texts)
    {:reply, clauses, s}
  end

  def handle_call({:commit_clauses, clauses}, _from, s) do
    {delta, s} = insert_clauses(s, clauses)
    # Only `added` is durable. Flagged clauses were refused — they are not part of
    # the KB, so replaying them would be replaying a rejection.
    persist(s, [{:clauses, delta.added}])
    {:reply, delta, s}
  end

  def handle_call({:check_constraints, timeout_s}, _from, s) do
    violations =
      s.clauses
      |> Enum.filter(&(&1.kind == "constraint"))
      |> Enum.flat_map(&violation(s.conn, &1, timeout_s))

    {:reply, violations, s}
  end

  def handle_call({:add_message, turn, kind, fields}, _from, s) do
    id = "m#{s.next_message}"
    message = Map.merge(%{id: id, kind: to_string(kind), turn: turn}, fields)
    s = %{s | next_message: s.next_message + 1, transcript: s.transcript ++ [message]}

    # An `assistant` message is opened empty here and filled by streamed tokens, so
    # it is not final yet — `finish_assistant/3` persists it instead. Every other
    # kind arrives complete, which is what keeps a reply to one write rather than
    # one per token.
    unless kind == :assistant, do: persist(s, [{:message, message}])

    {:reply, message, s}
  end

  def handle_call({:finish_assistant, id, text}, _from, s) do
    existing = Enum.find(s.transcript, &(&1.id == id)) || %{id: id, kind: "assistant", turn: nil}
    message = Map.put(existing, :text, text)
    persist(s, [{:message, message}])
    {:reply, message, %{s | transcript: replace_message(s.transcript, message)}}
  end

  def handle_call({:run_turn, turn, text, subscriber}, _from, %{turn: nil} = s) do
    {pid, ref} = spawn_monitor(Turn, :run, [self(), turn, text, subscriber])
    {:reply, :ok, %{s | turn: %{id: turn, pid: pid, ref: ref, subscriber: subscriber}}}
  end

  def handle_call({:run_turn, _turn, _text, _subscriber}, _from, s) do
    {:reply, {:error, :turn_in_flight}, s}
  end

  def handle_call(:cancel_turn, _from, %{turn: nil} = s), do: {:reply, :ok, s}

  def handle_call(:cancel_turn, _from, %{turn: t} = s) do
    # Killing the loop is the whole cancel: it drops the llama connection (which
    # stops generation) and abandons any in-flight MQI call, which the per-query
    # timeout then reaps. Asserted clauses stay.
    Process.demonitor(t.ref, [:flush])
    Process.exit(t.pid, :kill)
    Event.emit(t.subscriber, :turn_done, t.id, %{})
    {:reply, :ok, %{s | turn: nil}}
  end

  @impl true
  def handle_cast({:append_assistant, id, delta}, s) do
    case Enum.find(s.transcript, &(&1.id == id)) do
      nil -> {:noreply, s}
      m -> {:noreply, %{s | transcript: replace_message(s.transcript, %{m | text: m.text <> delta})}}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{turn: %{ref: ref} = t} = s) do
    unless reason == :normal do
      Logger.error("[conversation] turn #{t.id} died: #{inspect(reason)}")
      Event.error(t.subscriber, t.id, "internal", "turn failed: #{inspect(reason)}")
      Event.emit(t.subscriber, :turn_done, t.id, %{})
    end

    {:noreply, %{s | turn: nil}}
  end

  def handle_info(_msg, s), do: {:noreply, s}

  @impl true
  def terminate(_reason, s) do
    # Nothing is flushed here on purpose: every append has already been synced, so
    # a conversation is exactly as durable after a `:kill` — which never reaches
    # `terminate/2` — as after a graceful stop. This only releases handles.
    Store.close(s.store)
    MQI.close(s.conn)
    :ok
  end

  # --- internals -------------------------------------------------------------

  # Durability is synchronous and happens before the caller is replied to, so a
  # turn that has been acknowledged has already hit the disk.
  defp persist(s, events), do: Store.append(s.store, events)

  # Declare-then-assert, in one round trip.
  #
  # This is what makes a conversation's knowledge base actually private. MQI gives
  # each connection its own *thread* but not its own database: an ordinary
  # `assertz/1` writes to the process-global store, where every other conversation
  # can read it. Declaring the predicate `thread_local` first confines its clauses
  # to this connection's thread — and discards them when the thread ends, which is
  # why a rehydrated conversation replays into a clean engine instead of doubling
  # what is already there.
  #
  # The order is not a style choice. A predicate asserted *before* being declared
  # can never be declared afterwards — SWI answers `permission_error` — and its
  # clauses are then permanently global for the life of the swipl process. So the
  # two must travel together, and every path that asserts must come through here.
  # `thread_local/1` is idempotent, so repeating it per clause costs nothing.
  defp assertion(text) do
    body = Clause.body(text)

    case Clause.head_signature(text) do
      nil -> "assertz((#{body}))"
      signature -> "thread_local(#{signature}), assertz((#{body}))"
    end
  end

  defp name_for(opts) do
    cond do
      opts[:name] -> opts[:name]
      opts[:id] -> via(opts[:id])
      true -> nil
    end
  end

  # Assign ids and classify, without touching Prolog.
  defp mint_clauses(s, turn, texts) do
    Enum.map_reduce(texts, s, fn text, acc ->
      canonical = Clause.normalize(text)

      clause = %{
        id: "c#{acc.next_clause}",
        text: canonical,
        kind: canonical |> Clause.kind() |> to_string(),
        turn: turn
      }

      {clause, %{acc | next_clause: acc.next_clause + 1}}
    end)
  end

  defp insert_clauses(s, clauses) do
    {added, flagged} =
      Enum.reduce(clauses, {[], []}, fn clause, {added, flagged} ->
        case Clause.rejection(clause.text) do
          # Refused before it reaches Prolog. Reporting it as `flagged` rather than
          # dropping it silently is deliberate: the UI shows the clause with its
          # reason, which is far more useful than a KB that has quietly started
          # answering every question about that predicate `true`.
          reason when is_binary(reason) ->
            {added, [%{id: clause.id, reason: reason} | flagged]}

          nil ->
            # A successful assertz answers `true` or leaks the clause's (unbound)
            # variable bindings — both mean success.
            case MQI.run(s.conn, assertion(clause.text)) do
              {:ok, false} -> {added, [%{id: clause.id, reason: "assert failed"} | flagged]}
              {:ok, _} -> {[clause | added], flagged}
              {:error, reason} -> {added, [%{id: clause.id, reason: to_string(reason)} | flagged]}
            end
        end
      end)

    added = Enum.reverse(added)
    {%{added: added, flagged: Enum.reverse(flagged)}, %{s | clauses: s.clauses ++ added}}
  end

  defp violation(conn, constraint, timeout_s) do
    goal = Clause.constraint_goal(constraint.text)

    case MQI.run(conn, goal, timeout_s) do
      {:ok, false} ->
        []

      {:ok, result} ->
        [%{constraint: constraint, witness: Answer.witness(result)}]

      {:error, reason} ->
        Logger.debug("[conversation] constraint #{constraint.id} unchecked: #{inspect(reason)}")
        []
    end
  end

  defp predicates(clauses) do
    clauses |> Enum.flat_map(&Clause.signatures(&1.text)) |> Enum.uniq()
  end

  defp replace_message(transcript, message) do
    Enum.map(transcript, fn m -> if m.id == message.id, do: message, else: m end)
  end
end
