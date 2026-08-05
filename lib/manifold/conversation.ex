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

  If `:prelude_path` is configured (`MANIFOLD_PRELUDE`), that file is `consult/1`ed into
  every engine at startup, before replay and before anything else can touch it — see
  `consult_prelude/1`. It is background knowledge shared by every conversation, not a
  conversation input: it is not part of `kb_snapshot/1` and is not written to the log.

  `run_turn/4` executes the sealed turn loop. The loop itself runs in a *separate,
  monitored process* (`Manifold.Turn`), for two reasons: this GenServer stays
  responsive to `kb_request` and `cancel_turn` while the model generates, and a
  cancel is then just killing that process. The KB is only ever touched through
  calls back into here, so it stays serialised.

  Started under `Manifold.Conversation.Supervisor` via `Manifold.start_conversation/1`
  and, when given an `:id`, registered in `Manifold.Conversation.Registry` so a
  reconnecting socket can find it again.
  """
  # `:temporary`, not `:transient`, for two reasons that only appear once each
  # conversation owns a fallible OS process:
  #
  #   * Blast radius. A DynamicSupervisor defaults to `max_restarts: 3, max_seconds: 5`.
  #     One conversation whose engine cannot boot would crash-loop, exceed the intensity,
  #     and take the *supervisor* down — killing every other live conversation. Temporary
  #     children are never restarted, so they cannot contribute to restart intensity.
  #   * Race. Under `:transient` there is a window during automatic restart where the
  #     registry entry is absent, so a concurrent `open_conversation(id)` misses the
  #     lookup and starts a *second* conversation for the same id — two engines and two
  #     store handles appending to one log.
  #
  # Recovery is the client's reconnect instead, which is strictly better informed: the
  # socket reports the death, the client re-`open`s, and `Manifold.Store` rehydrates.
  use GenServer, restart: :temporary
  require Logger

  alias Manifold.{Clause, Event, Store, Turn}
  alias Manifold.Prolog.{Answer, Engine, MQI}

  @registry Manifold.Conversation.Registry

  # A constraint body is a goal like any other: it needs a kill switch.
  @check_timeout_s 5

  # Snapshots can be requested while `handle_continue(:rehydrate, …)` is still replaying,
  # so they need more than the 5 s default — otherwise a large knowledge base times out
  # the *socket* (dropping the client) while the conversation is perfectly healthy.
  @snapshot_timeout 60_000

  # One timer for the life of the conversation, compared against a monotonic stamp.
  # Deliberately not the GenServer `:timeout` return value: that would have to be
  # threaded through every one of ~15 return points and is silently lost the first time
  # someone adds a clause without it.
  #
  # The interval scales with the timeout instead of being a flat minute, so that a short
  # timeout is actually honoured promptly — 60 s granularity on a 15-minute timeout is
  # irrelevant, but on a 5-second one it is the whole behaviour.
  @idle_check_cap_ms 60_000
  @idle_check_floor_ms 500

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

  @doc """
  Register `subscriber` as attached to this conversation, and report engine readiness.

  Attachment exists so idle eviction can tell a genuinely abandoned conversation from
  one whose browser tab is simply quiet: evicting the latter would be pure churn, since
  the client would immediately reconnect and force a rehydrate. It also makes "the
  conversation must outlive its socket" an explicit contract rather than an accident.

  The conversation monitors `subscriber` and drops it when it goes away.
  """
  @spec attach(pid(), pid()) :: %{prolog: boolean()}
  def attach(pid, subscriber), do: GenServer.call(pid, {:attach, subscriber})

  @doc "Every clause in the KB, oldest first — the `kb_snapshot` payload."
  @spec kb_snapshot(pid()) :: [clause()]
  def kb_snapshot(pid), do: GenServer.call(pid, :kb_snapshot, @snapshot_timeout)

  @doc "Every transcript message, oldest first — the `transcript_snapshot` payload."
  @spec transcript_snapshot(pid()) :: [message()]
  def transcript_snapshot(pid), do: GenServer.call(pid, :transcript_snapshot, @snapshot_timeout)

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
    # Owning the engine's Port is what makes the engine unable to outlive this process:
    # when we exit for *any* reason, including `:kill`, the port closes and the sh
    # guardian reaps swipl. Trapping exits is what lets us also hear about the port
    # dying, and is a precondition for `terminate/2` running at all — a GenServer that
    # does not trap exits is killed outright by the supervisor's `:shutdown`.
    Process.flag(:trap_exit, true)

    with {:ok, engine} <- Engine.start(),
         {:ok, engine} <- Engine.await_ready(engine),
         {:ok, conn} <- Engine.connect(engine),
         {:ok, engine} <- Engine.identify(engine, conn),
         # Ahead of the `unknown` flag below, and ahead of replay: a directive in the
         # prelude that calls something undefined should throw, not silently fail, and
         # anything the prelude defines must already be there for the first replayed
         # clause or live turn to see.
         :ok <- consult_prelude(conn),
         # Integrity constraints mention predicates that may not exist yet; without this
         # an undefined predicate throws existence_error instead of failing, and every
         # check would look like an error rather than "no violation". Per engine.
         {:ok, _} <- MQI.run(conn, "set_prolog_flag(unknown, fail)") do
      Process.send_after(self(), :idle_check, idle_check_ms())

      state = %{
        id: opts[:id],
        engine: engine,
        conn: conn,
        store: nil,
        clauses: [],
        transcript: [],
        next_clause: 1,
        next_message: 1,
        turn: nil,
        attached: %{},
        last_activity: now()
      }

      # Publish the engine's OS pid as our registry value, so `Manifold.kill_engine/1`
      # can signal it *without* going through this mailbox. That matters precisely when
      # the kill switch is needed: a conversation blocked in `MQI.run/3` on a runaway
      # goal cannot answer a call until that goal returns.
      if opts[:id] do
        Registry.update_value(@registry, opts[:id], fn _ -> %{os_pid: Engine.os_pid(engine)} end)
      end

      # Everything whose failure means "cannot start" belongs above, in `init/1`, where
      # `{:stop, reason}` is *not* a crash: `start_child` simply returns `{:error,
      # reason}` and the socket renders it as `error{prolog_unavailable}`. Replay goes
      # below, where a failure means the engine just died and crashing is right.
      {:ok, state, {:continue, :rehydrate}}
    else
      {:error, reason} -> {:stop, {:prolog_unavailable, reason}}
    end
  end

  @impl true
  def handle_continue(:rehydrate, s) do
    # Runs before any queued message, so no caller can observe a half-built KB and there
    # is no "not ready yet" state to represent — a call simply takes longer.
    {:noreply, rehydrate(%{s | store: Store.open(s.id)})}
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
    {:reply, results, touch(s)}
  end

  def handle_call({:query, goal, timeout_s}, _from, s) do
    case MQI.run(s.conn, goal, timeout_s) do
      # The engine is gone, so this is not an answer. Handing it back as one is how a
      # dead knowledge base starts quietly lying — the caller cannot tell "Prolog says
      # no" from "the socket is dead". Stop, and let the client's reconnect rehydrate.
      {:error, {:transport, reason}} = err ->
        Logger.error("[conversation] #{s.id}: engine transport failed: #{inspect(reason)}")
        {:stop, {:mqi_transport, reason}, err, s}

      result ->
        {:reply, result, touch(s)}
    end
  end

  def handle_call({:attach, subscriber}, _from, s) do
    ref = Process.monitor(subscriber)
    {:reply, %{prolog: true}, touch(%{s | attached: Map.put(s.attached, ref, subscriber)})}
  end

  def handle_call(:kb_size, _from, s), do: {:reply, length(s.clauses), s}
  def handle_call(:kb_snapshot, _from, s), do: {:reply, s.clauses, touch(s)}
  def handle_call(:transcript_snapshot, _from, s), do: {:reply, s.transcript, touch(s)}
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
    {:reply, :ok, touch(%{s | turn: %{id: turn, pid: pid, ref: ref, subscriber: subscriber}})}
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

  # An attached client went away. The conversation deliberately survives it — that is
  # what makes `open {conversation_id}` reconnects work — but it now becomes evictable.
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{attached: attached} = s)
      when is_map_key(attached, ref) do
    {:noreply, %{s | attached: Map.delete(attached, ref)}}
  end

  def handle_info(:idle_check, s) do
    Process.send_after(self(), :idle_check, idle_check_ms())
    idle_ms = now() - s.last_activity

    # All three conditions matter. A turn in flight is never evictable however long it
    # has been generating; an attached client means eviction would only cause an
    # immediate reconnect and rehydrate, which is pure churn.
    if idle_ms > idle_timeout() and s.turn == nil and s.attached == %{} do
      Logger.info(
        "[conversation] #{s.id}: evicted after #{div(idle_ms, 1000)}s idle " <>
          "(#{length(s.clauses)} clauses, #{length(s.transcript)} messages)"
      )

      # `:normal` on purpose: it is what lets the socket tell eviction apart from a crash
      # and re-open transparently, and it is not a restart trigger under any strategy.
      {:stop, :normal, s}
    else
      {:noreply, s}
    end
  end

  # --- the engine's own port -------------------------------------------------
  #
  # These must sit above the catch-all below, which would otherwise swallow the death of
  # the knowledge base and leave us serving a corpse.

  def handle_info({port, {:exit_status, code}}, %{engine: %{port: port}} = s) do
    Logger.error("[conversation] #{s.id}: swipl exited status=#{code}")
    {:stop, {:engine_exited, code}, s}
  end

  def handle_info({port, {:data, chunk}}, %{engine: %{port: port} = engine} = s) do
    {:noreply, %{s | engine: Engine.log_data(engine, chunk)}}
  end

  def handle_info({:EXIT, port, reason}, %{engine: %{port: port}} = s) do
    {:stop, {:engine_port_down, reason}, s}
  end

  def handle_info(_msg, s), do: {:noreply, s}

  @impl true
  def terminate(_reason, s) do
    # Nothing is flushed here on purpose: every append has already been synced, so a
    # conversation is exactly as durable after a `:kill` — which never reaches
    # `terminate/2` — as after a graceful stop. This only releases handles.
    #
    # Stopping the engine is likewise a tidiness measure, not the guarantee: closing our
    # port would reap swipl regardless, which is what covers the `:kill` path.
    if s.store, do: Store.close(s.store)
    MQI.close(s.conn)
    Engine.stop(s.engine)
    :ok
  end

  # --- internals -------------------------------------------------------------

  # Durability is synchronous and happens before the caller is replied to, so a
  # turn that has been acknowledged has already hit the disk.
  defp persist(s, events), do: Store.append(s.store, events)

  # Bumped only by client-driven entry points. Deliberately *not* by streamed assistant
  # tokens (already covered by the enclosing turn) or the turn's own DOWN.
  defp touch(s), do: %{s | last_activity: now()}

  defp now, do: System.monotonic_time(:millisecond)

  defp idle_timeout, do: Application.get_env(:manifold, :conversation_idle_ms, 900_000)

  defp idle_check_ms do
    idle_timeout()
    |> div(4)
    |> min(@idle_check_cap_ms)
    |> max(@idle_check_floor_ms)
  end

  # `consult/1` a background Prolog file into a freshly connected engine, or do nothing
  # when none is configured (the default). A misconfigured prelude — missing file, a
  # syntax error, a failing directive — fails engine startup the same way a missing
  # `swipl` does: surfacing as `error{prolog_unavailable}` beats booting a conversation
  # silently short of the rules it was told to have.
  #
  # `consult/1` is fine to run over MQI here even though it is a foreign predicate that
  # touches the filesystem: unlike `assertz/1` in the rest of this module, there is no
  # per-clause id or `kind` to mint, and the file is not a conversation input — it is
  # infrastructure, identical for every conversation, so it does not belong in the KB
  # snapshot or the durable log. It is not re-consulted on rehydrate for the same reason
  # `rehydrate/1` never re-runs `persist/2`: a fresh engine already has it, from here.
  defp consult_prelude(conn) do
    case Application.get_env(:manifold, :prelude_path) do
      nil ->
        :ok

      path ->
        case MQI.run(conn, "consult('#{quote_atom(path)}')") do
          {:ok, _} -> :ok
          {:error, reason} -> {:error, {:prelude_failed, path, reason}}
        end
    end
  end

  # Escape a path for interpolation into a Prolog quoted atom: double any embedded `'`
  # (SWI's own escape for it) and neutralise `\`, which quoted-atom syntax treats as the
  # start of an escape sequence.
  defp quote_atom(text) do
    text |> String.replace("\\", "\\\\") |> String.replace("'", "\\'")
  end

  # A plain assert. Privacy comes from the engine being this conversation's own OS
  # process, so nothing needs declaring first.
  #
  # There used to be a `thread_local/1` declaration fused to every assert, because MQI
  # connections into one shared swipl share a global clause store. That is gone with the
  # shared server: it protected only clauses asserted through this one function, so any
  # other path — a debugging `MQI.run`, a `consult/1`, a future retract-then-assert —
  # leaked globally *and permanently*, since a predicate asserted before being declared
  # can never be declared afterwards. It also ruled out a second, read-only MQI
  # connection, which is the natural way to stop a long query blocking `kb_request`.
  #
  # The premise `rehydrate/1` depends on is not weakened by dropping it, but relocated
  # and strengthened: it used to rest on *thread* death discarding thread-local clauses,
  # and now rests on *process* death, where a fresh swipl has an empty everything —
  # clause store, flags, operator table.
  defp assertion(text), do: "assertz((#{Clause.body(text)}))"

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
