defmodule Manifold.Store.None do
  @moduledoc """
  The null store: accepts every write, replays nothing.

  Its purpose is to remove conditionals from `Manifold.Conversation`, which always
  has *a* store and never asks whether persistence is on. Used for id-less
  (ephemeral) conversations, when persistence is configured off, and as the
  degraded fallback when a real adapter fails to open.
  """
  @behaviour Manifold.Store

  @impl true
  def setup(_opts), do: :ok

  @impl true
  def open(_id, _opts), do: {:ok, nil}

  @impl true
  def append(_handle, _events), do: :ok

  @impl true
  def replay(_handle), do: {:ok, []}

  @impl true
  def close(_handle), do: :ok

  @impl true
  def delete(_id, _opts), do: :ok

  @impl true
  def list(_opts), do: {:ok, []}
end
