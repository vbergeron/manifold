defmodule Manifold.Event do
  @moduledoc """
  The protocol envelope (`docs/PROTOCOL.md`) and the one-way channel the turn
  loop uses to reach a socket.

  Every server→client frame is `%{v, type, seq, turn, ts, payload}`. Everything
  but `seq` is built here; `seq` is stamped by `Manifold.Web.Socket` because the
  counter is *per connection* — the turn loop runs in its own process and must
  not own it.

  Delivery is a bare `send/2` to the subscriber pid: `{:manifold_event, envelope}`.
  That is deliberately the cheapest thing that works — one socket owns one
  conversation, so there is nothing to fan out to and no registry to keep in sync.
  A `nil` subscriber makes emission a no-op, which is how the turn loop is driven
  headlessly from scripts and tests.
  """

  @version 1

  @type envelope :: %{v: pos_integer(), type: String.t(), turn: String.t() | nil, ts: integer(), payload: map()}

  @doc "The protocol version this server speaks."
  @spec version() :: pos_integer()
  def version, do: @version

  @doc "Build an envelope (without `seq`)."
  @spec new(atom() | String.t(), String.t() | nil, map()) :: envelope()
  def new(type, turn, payload \\ %{}) do
    %{
      v: @version,
      type: to_string(type),
      turn: turn,
      ts: System.system_time(:millisecond),
      payload: payload
    }
  end

  @doc "Send an envelope to a subscriber pid (no-op when `nil`)."
  @spec emit(pid() | nil, atom() | String.t(), String.t() | nil, map()) :: :ok
  def emit(nil, _type, _turn, _payload), do: :ok

  def emit(subscriber, type, turn, payload) when is_pid(subscriber) do
    send(subscriber, {:manifold_event, new(type, turn, payload)})
    :ok
  end

  @doc "Emit a typed `error` event (see the code table in `docs/PROTOCOL.md`)."
  @spec error(pid() | nil, String.t() | nil, String.t(), String.t()) :: :ok
  def error(subscriber, turn, code, message) do
    emit(subscriber, :error, turn, %{code: code, message: message})
  end
end
