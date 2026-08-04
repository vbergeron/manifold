defmodule Manifold.Store do
  @moduledoc """
  Persistence for a conversation, behind a swappable adapter.

  ## What is stored, and why so little

  A conversation's durable state is a list of clauses, a typed transcript, and two
  id counters. The **Prolog engine is not stored at all**: the KB is append-only in
  v1, so replaying `assertz` over the clause list reconstructs the engine exactly.
  Recovery therefore runs the same insertion path as a live turn, and there stays
  one way a clause can enter Prolog.

  ## Why an event log rather than a snapshot

  The interface is `append/2` + `replay/1` over *batches of domain events*, not
  `save(state)` / `load()`. That choice is what lets one interface fit both
  targets:

    * a batch is one `:file.write` for `Manifold.Store.Log`;
    * a batch is one `:mnesia.transaction/1` for a future Mnesia adapter.

  Snapshot semantics would invert the cost: natural for Mnesia, an O(n) rewrite of
  the whole conversation on every turn for a log. Batching is also what makes a
  turn *atomic* — a turn's clauses and its transcript entries commit together or
  not at all.

  ## Counters are derived, not stored

  `next_clause` / `next_message` come from the highest id replayed, so the event
  vocabulary stays purely domain-shaped. The one visible consequence: ids burned
  by `prepare_clauses/3` on clauses that were then rejected get reused after a
  restart. That is harmless — a reconnecting client re-takes both snapshots
  (`docs/PROTOCOL.md`, "Reconnect"), so it never holds a stale id.

  ## Adapters

    * `Manifold.Store.None` — no-op. The default for a conversation with no id, so
      `Manifold.Conversation` needs no "is persistence on?" branch anywhere.
    * `Manifold.Store.Log` — append-only ETF log, one file per conversation.
    * Mnesia — planned, for multi-node. Sketch: an `ordered_set` table keyed
      `{conversation_id, seq}` with `disc_copies`; `append/2` writes the batch in
      one transaction, `replay/1` walks the key range for one conversation, which
      is already in order. Nothing in this behaviour needs to change for it.

  Configure with `{module, opts}`:

      config :manifold, store: {Manifold.Store.Log, dir: "data"}
      config :manifold, store: Manifold.Store.None    # opts default to []

  ## Failure policy

  A conversation whose store cannot be opened degrades to `None` with an error
  logged, rather than refusing to start: losing durability is bad, but refusing to
  hold a conversation at all is worse. Replay stops at the first record it cannot
  decode — see `Manifold.Store.Log` for why that is the *correct* reading of a
  torn tail rather than data loss.
  """
  require Logger

  @type id :: String.t()

  @typedoc """
  A durable domain event.

    * `{:clauses, [clause]}` — clauses that made it into the KB. Rejected and
      flagged clauses are deliberately absent: they are not part of the KB.
    * `{:message, message}` — a transcript entry in its *final* form. Streamed
      assistant tokens are never events; only the completed message is, which is
      what keeps a reply from costing one write per token.
  """
  @type event :: {:clauses, [map()]} | {:message, map()}

  @typedoc "An opaque per-conversation handle, paired with the adapter that made it."
  @type t :: %__MODULE__{mod: module(), handle: term()}

  defstruct [:mod, :handle]

  @doc "Prepare the store to be used at all — create directories, tables, schema."
  @callback setup(keyword()) :: :ok | {:error, term()}

  @doc "Open (creating if absent) the durable state for one conversation."
  @callback open(id(), keyword()) :: {:ok, term()} | {:error, term()}

  @doc "Durably append a batch. Must be atomic across the batch, and must have hit disk on return."
  @callback append(term(), [event()]) :: :ok | {:error, term()}

  @doc "Every event for this conversation, oldest first."
  @callback replay(term()) :: {:ok, [event()]} | {:error, term()}

  @doc "Release any per-conversation resource. Never fails."
  @callback close(term()) :: :ok

  @doc "Forget a conversation entirely."
  @callback delete(id(), keyword()) :: :ok | {:error, term()}

  @doc "Every conversation id the store knows about."
  @callback list(keyword()) :: {:ok, [id()]} | {:error, term()}

  @default {Manifold.Store.Log, [dir: "data"]}

  @doc "The configured adapter as `{module, opts}`."
  @spec adapter() :: {module(), keyword()}
  def adapter do
    case Application.get_env(:manifold, :store, @default) do
      {mod, opts} when is_atom(mod) and is_list(opts) -> {mod, opts}
      mod when is_atom(mod) -> {mod, []}
    end
  end

  @doc "Run the adapter's one-time setup. Called from `Manifold.Application`."
  @spec setup() :: :ok | {:error, term()}
  def setup do
    {mod, opts} = adapter()
    mod.setup(opts)
  end

  @doc """
  Open the store for `id`, or an ephemeral no-op store when `id` is `nil`.

  An id-less conversation (`Manifold.start_conversation/1` with no `:id`, as used
  from IEx and the smoke scripts) is deliberately not persisted: it cannot be
  re-attached to, so there is nothing a durable copy could be used for.
  """
  @spec open(id() | nil) :: t()
  def open(nil), do: none()

  def open(id) do
    {mod, opts} = adapter()

    case mod.open(id, opts) do
      {:ok, handle} ->
        %__MODULE__{mod: mod, handle: handle}

      {:error, reason} ->
        Logger.error(
          "[store] #{inspect(mod)} could not open #{id}: #{inspect(reason)} — this conversation will not be durable"
        )

        none()
    end
  end

  @doc "Append a batch of events. Empty batches never reach the adapter."
  @spec append(t(), [event()]) :: :ok
  def append(_store, []), do: :ok

  def append(%__MODULE__{mod: mod, handle: handle}, events) do
    case mod.append(handle, events) do
      :ok ->
        :ok

      {:error, reason} ->
        # Losing the write is reported but not fatal: the in-memory conversation is
        # still correct, and killing a live turn over a disk error would trade a
        # durability failure for an availability one.
        Logger.error("[store] #{inspect(mod)} append failed: #{inspect(reason)}")
        :ok
    end
  end

  @doc "Every event for this conversation, oldest first. Failure replays as empty."
  @spec replay(t()) :: [event()]
  def replay(%__MODULE__{mod: mod, handle: handle}) do
    case mod.replay(handle) do
      {:ok, events} ->
        events

      {:error, reason} ->
        Logger.error("[store] #{inspect(mod)} replay failed: #{inspect(reason)}")
        []
    end
  end

  @spec close(t()) :: :ok
  def close(%__MODULE__{mod: mod, handle: handle}), do: mod.close(handle)

  @spec delete(id()) :: :ok | {:error, term()}
  def delete(id) do
    {mod, opts} = adapter()
    mod.delete(id, opts)
  end

  @spec list() :: {:ok, [id()]} | {:error, term()}
  def list do
    {mod, opts} = adapter()
    mod.list(opts)
  end

  defp none, do: %__MODULE__{mod: Manifold.Store.None, handle: nil}
end
