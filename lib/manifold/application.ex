defmodule Manifold.Application do
  @moduledoc """
  The Manifold OTP application.

  Boots a supervision tree:

      Manifold.Supervisor            (one_for_one)
      ├── Manifold.Llama.Server      llama.cpp server   (OS process via Port)
      ├── Manifold.Conversation.Registry  conversation_id -> pid, for reconnects
      ├── Manifold.Conversation.Sup  DynamicSupervisor — one child per conversation,
      │                              each owning its own swipl OS process.
      └── Bandit                     HTTP/WebSocket endpoint (`Manifold.Web.Router`)

  There is deliberately **no** Prolog server here. Prolog is not a shared sidecar: each
  conversation launches and owns its own `swipl` (see `Manifold.Prolog.Engine`), because
  MQI connections to one process share a global clause store and would leak every
  conversation's knowledge base into every other's. Nothing therefore needs to precede
  conversations at boot.

  The endpoint is last: it may accept connections before the model is loaded, and reports
  that honestly in the `session` event's `sidecars` field.
  """
  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    port = Application.get_env(:manifold, :web_port, 4000)

    # Before any conversation can be opened: create the log directory, or the
    # Mnesia schema, or nothing at all, depending on the configured adapter. A
    # store that cannot be prepared is logged and the app still boots — the same
    # posture as a missing model, since a conversation without durability is
    # degraded rather than broken.
    case Manifold.Store.setup() do
      :ok -> :ok
      {:error, reason} -> Logger.error("[store] setup failed: #{inspect(reason)} — conversations will not be durable")
    end

    # Resolve `swipl` once rather than on every conversation open: it answers
    # `Manifold.ready?/0` without needing a process (so it cannot exit `:noproc` and take
    # `/health` down with it), and saves `Engine.start/0` a PATH walk per engine.
    :persistent_term.put({Manifold, :swipl}, System.find_executable("swipl"))

    if is_nil(:persistent_term.get({Manifold, :swipl}, nil)) do
      Logger.warning("[engine] `swipl` not found on PATH — conversations cannot be opened")
    end

    warn_about_orphans()

    children = [
      Manifold.Llama.Server,
      {Registry, keys: :unique, name: Manifold.Conversation.Registry},
      {DynamicSupervisor,
       name: Manifold.Conversation.Supervisor,
       strategy: :one_for_one,
       max_children: Application.get_env(:manifold, :max_conversations, 64)},
      {Bandit, plug: Manifold.Web.Router, scheme: :http, port: port}
    ]

    Logger.info("[web] listening on http://127.0.0.1:#{port} (ws://127.0.0.1:#{port}/socket)")

    Logger.info(
      "[engine] capacity=#{Application.get_env(:manifold, :max_conversations, 64)} " <>
        "idle_timeout=#{div(Application.get_env(:manifold, :conversation_idle_ms, 900_000), 1000)}s"
    )

    opts = [strategy: :one_for_one, name: Manifold.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Deliberately a warning and not a reaper. Leftover guardians mean either that the
  # guardian's cleanup regressed or that a second Manifold is running on this box, and
  # those are indistinguishable from here — so killing them could take out a healthy
  # instance's engines. The warning is the part that has value: it is how you find out
  # the guardian stopped working.
  defp warn_about_orphans do
    case count_guardians() do
      n when n > 0 ->
        Logger.warning(
          "[engine] #{n} orphaned guardian process(es) already running — a previous run leaked, or another instance is up"
        )

      _ ->
        :ok
    end
  end

  # Matches `manifold-guardian` as an *exact argv entry*, not as a substring of the
  # command line. `pgrep -f` would do the latter and so count any shell that merely
  # mentions the word — including a shell running the check itself. A diagnostic that
  # cries wolf at every boot is worse than none, because it teaches operators to ignore
  # the one time it is real.
  defp count_guardians do
    case File.ls("/proc") do
      {:ok, entries} ->
        entries
        |> Enum.filter(&match?({_, ""}, Integer.parse(&1)))
        |> Enum.count(&guardian?/1)

      {:error, _} ->
        0
    end
  end

  defp guardian?(pid) do
    case File.read("/proc/#{pid}/cmdline") do
      {:ok, raw} -> "manifold-guardian" in String.split(raw, <<0>>)
      {:error, _} -> false
    end
  end
end
