defmodule Manifold do
  @moduledoc """
  Manifold — a conversational AI whose every conversation is *doubled* by a live
  Prolog session.

  The OTP application (`Manifold.Application`) supervises two independent sidecar
  servers as OS processes:

    * `Manifold.Llama.Server` — a `llama.cpp` HTTP server. GBNF-constrained
      decoding (`Manifold.Grammar.prolog/0`) forces the model to emit valid
      Prolog. Talk to it via `Manifold.Llama.Client`.
    * `Manifold.Prolog.Server` — a SWI-Prolog MQI server. Each conversation gets
      its own connection, and asserts through `thread_local` predicates so that
      connection really is its own knowledge base — MQI does not give one per
      connection for free. See `Manifold.Prolog.MQI`.

  A conversation is a `Manifold.Conversation` process pairing the NL transcript
  with that KB. This module is the thin public facade.
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
        case start_conversation(id: id) do
          {:ok, pid} -> {:ok, id, pid}
          {:error, {:already_started, pid}} -> {:ok, id, pid}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defdelegate assert(pid, clauses), to: Manifold.Conversation
  defdelegate query(pid, goal), to: Manifold.Conversation
  defdelegate query(pid, goal, timeout_s), to: Manifold.Conversation

  @doc "Readiness of the two supervised sidecars."
  @spec ready?() :: %{llama: boolean(), prolog: boolean()}
  def ready? do
    %{llama: Manifold.Llama.Server.ready?(), prolog: Manifold.Prolog.Server.ready?()}
  end
end
