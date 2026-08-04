defmodule Manifold do
  @moduledoc """
  Manifold — a conversational AI whose every conversation is *doubled* by a live
  Prolog session.

  Two very different resources sit behind this facade:

    * `Manifold.Llama.Server` — **one shared** `llama.cpp` HTTP server, supervised as an
      OS process. GBNF-constrained decoding (`Manifold.Grammar.prolog/0`) forces the
      model to emit valid Prolog. Talk to it via `Manifold.Llama.Client`.
    * `Manifold.Prolog.Engine` — **one per conversation**, owned by the
      `Manifold.Conversation` process itself rather than supervised centrally. MQI
      connections into a single swipl share a global clause store, so a shared server
      would merge every conversation's knowledge base into every other's.

  A conversation is a `Manifold.Conversation` process pairing the NL transcript with
  that private KB, durable through `Manifold.Store`.

  Note the asymmetry when reasoning about concurrency: an engine per conversation does
  *not* make turns concurrent. `llama-server` runs with `n_parallel` at its default of 1,
  so generation serialises across all conversations regardless of engine count.
  """

  @doc "Start a new doubled conversation under the conversation supervisor."
  @spec start_conversation(keyword()) :: DynamicSupervisor.on_start_child()
  def start_conversation(opts \\ []) do
    DynamicSupervisor.start_child(Manifold.Conversation.Supervisor, {Manifold.Conversation, opts})
  end

  @doc """
  Attach to the conversation named `id`, starting it if it isn't running; `nil`
  mints a fresh id. This is what the protocol's `open` command resolves to, and
  the reason reconnecting needs no replay buffer: the process (and therefore the
  KB and transcript) is still there, found by id in the registry.
  """
  @spec open_conversation(String.t() | nil) :: {:ok, String.t(), pid()} | {:error, term()}
  def open_conversation(nil), do: open_conversation(Manifold.Conversation.new_id())

  def open_conversation(id) when is_binary(id) do
    case Registry.lookup(Manifold.Conversation.Registry, id) do
      [{pid, _value}] ->
        {:ok, id, pid}

      [] ->
        # The capacity check goes *after* the lookup, and the order is load-bearing: a
        # full server must still let already-admitted users reconnect to conversations
        # they are holding, rather than locking them out of their own state.
        if at_capacity?() do
          {:error, :at_capacity}
        else
          case start_conversation(id: id) do
            {:ok, pid} -> {:ok, id, pid}
            {:error, {:already_started, pid}} -> {:ok, id, pid}
            # `max_children` is the unraceable backstop; because `Registry.count/1` does
            # not see id-less conversations it can fire even when the check above passed.
            {:error, :max_children} -> {:error, :at_capacity}
            {:error, reason} -> {:error, reason}
          end
        end
    end
  end

  @doc "Stop a conversation and its engine. Its knowledge base stays on disk."
  @spec stop_conversation(String.t() | pid()) :: :ok | {:error, :not_found}
  def stop_conversation(id) when is_binary(id) do
    case Registry.lookup(Manifold.Conversation.Registry, id) do
      [{pid, _}] -> stop_conversation(pid)
      [] -> {:error, :not_found}
    end
  end

  def stop_conversation(pid) when is_pid(pid) do
    DynamicSupervisor.terminate_child(Manifold.Conversation.Supervisor, pid)
  end

  @doc "How many conversations are live, and the cap."
  @spec conversations() :: %{live: non_neg_integer(), capacity: pos_integer()}
  def conversations do
    %{live: Registry.count(Manifold.Conversation.Registry), capacity: max_conversations()}
  end

  @doc """
  SIGKILL a conversation's engine — the runaway-query kill switch of last resort.

  Reads the engine's OS pid from the registry value rather than asking the conversation,
  because a conversation blocked in `MQI.run/3` on the runaway goal cannot answer a call
  until that goal returns. It is `SIGKILL` rather than `SIGTERM` for the same reason a
  per-query timeout can fail to fire: a goal spinning inside a foreign predicate may
  never reach a signal handler.

  Non-destructive: the conversation dies with its engine and rehydrates from its log,
  losing only the in-flight query, and no other conversation is touched.
  """
  @spec kill_engine(String.t()) :: :ok | {:error, :not_found}
  def kill_engine(id) when is_binary(id) do
    case Registry.lookup(Manifold.Conversation.Registry, id) do
      [{_pid, %{os_pid: os_pid}}] -> Manifold.OsProcess.kill(os_pid, "KILL")
      _ -> {:error, :not_found}
    end
  end

  defdelegate assert(pid, clauses), to: Manifold.Conversation
  defdelegate query(pid, goal), to: Manifold.Conversation
  defdelegate query(pid, goal, timeout_s), to: Manifold.Conversation

  @doc """
  Readiness of what is shared.

  `prolog` means **engines can be spawned** — `swipl` is on `PATH` and we are below
  capacity — not that any particular engine is up. There is no global Prolog server to be
  up or down any more, and a conversation's own engine failing surfaces per-open as
  `error{prolog_unavailable}`.
  """
  @spec ready?() :: %{llama: boolean(), prolog: boolean()}
  def ready? do
    %{llama: Manifold.Llama.Server.ready?(), prolog: engines_available?()}
  end

  @doc "Whether a new engine could be started at all."
  @spec engines_available?() :: boolean()
  def engines_available? do
    not is_nil(:persistent_term.get({Manifold, :swipl}, nil)) and not at_capacity?()
  end

  # `Registry.count/1` is a lock-free ETS read. `DynamicSupervisor.count_children/1`
  # would be a call that queues behind in-flight engine boots, making this slow exactly
  # when it is most needed.
  defp at_capacity?, do: Registry.count(Manifold.Conversation.Registry) >= max_conversations()

  defp max_conversations, do: Application.get_env(:manifold, :max_conversations, 64)
end
