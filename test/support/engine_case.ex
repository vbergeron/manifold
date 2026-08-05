defmodule Manifold.EngineCase do
  @moduledoc """
  Case template for tests that need a real `swipl` engine.

  Every conversation it opens is stopped in `on_exit`. That is not housekeeping: a
  conversation *owns* an OS process, so a leaked conversation is a leaked swipl for the rest
  of the run. The scripts this replaces leaked four of them per run, which is also why their
  `pgrep`-based engine count could pass spuriously.

  Tagged `:swipl` at the module level, so a machine without SWI-Prolog can run the rest of
  the suite with `mix test --exclude swipl`.
  """
  use ExUnit.CaseTemplate

  using do
    quote do
      import Manifold.EngineCase

      alias Manifold.Conversation

      @moduletag :swipl
      # Engine boots are ~90 ms and a few tests kill and rehydrate, which is slower than
      # ExUnit's 60 s default is generous about when the machine is loaded.
      @moduletag timeout: 120_000
    end
  end

  @doc """
  Open a conversation that will be stopped when the test ends.

  Pass `id: nil` (the default) for a fresh minted id. Returns `{id, pid}`.
  """
  def open_conversation!(id \\ nil) do
    {:ok, id, pid} = Manifold.open_conversation(id)
    on_exit(fn -> stop_quietly(id) end)
    {id, pid}
  end

  @doc """
  Override an application env key for the duration of the test, restoring it afterwards.

  Used for `:conversation_idle_ms` and `:max_conversations`, which are read at call time
  rather than captured at boot, so an override takes effect immediately.
  """
  def put_env!(key, value) do
    previous = Application.fetch_env(:manifold, key)
    Application.put_env(:manifold, key, value)

    on_exit(fn ->
      case previous do
        {:ok, old} -> Application.put_env(:manifold, key, old)
        :error -> Application.delete_env(:manifold, key)
      end
    end)
  end

  @doc "Number of live conversations, which is one engine each."
  def engine_count, do: Manifold.conversations().live

  @doc """
  Wait until `fun` returns truthy, or fail. For the genuinely asynchronous edges — an OS
  process dying, a supervisor noticing — where the alternative is a fixed sleep that is
  either flaky or slow.
  """
  def eventually(fun, timeout \\ 5_000) do
    eventually(fun, System.monotonic_time(:millisecond) + timeout, timeout)
  end

  defp eventually(fun, deadline, timeout) do
    cond do
      result = fun.() ->
        result

      System.monotonic_time(:millisecond) >= deadline ->
        raise ExUnit.AssertionError, message: "condition never became true within #{timeout}ms"

      true ->
        Process.sleep(25)
        eventually(fun, deadline, timeout)
    end
  end

  # A conversation may already be gone — evicted, killed by the test, or crashed on
  # purpose — so cleanup must tolerate that rather than failing an otherwise green test.
  defp stop_quietly(id) do
    Manifold.stop_conversation(id)
  catch
    :exit, _ -> :ok
  end
end
