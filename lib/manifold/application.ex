defmodule Manifold.Application do
  @moduledoc """
  The Manifold OTP application.

  Boots a supervision tree that owns the two sidecar servers as *independent*,
  supervised OS processes — each in its own `Port`, each restarted on its own:

      Manifold.Supervisor            (one_for_one)
      ├── Manifold.Prolog.Server     swipl MQI server   (OS process via Port)
      ├── Manifold.Llama.Server      llama.cpp server   (OS process via Port)
      ├── Manifold.Conversation.Registry  conversation_id -> pid, for reconnects
      ├── Manifold.Conversation.Sup  DynamicSupervisor — one child per conversation,
      │                              each holding its own Prolog KB connection.
      └── Bandit                     HTTP/WebSocket endpoint (`Manifold.Web.Router`)

  `one_for_one` means a crash in the LLM server does not take down the Prolog
  server (or vice-versa); the supervisor restarts only the one that died. This
  is the crash-isolation that made Elixir the right host for this design. The
  endpoint is last: it may accept connections before the sidecars are ready, and
  reports that honestly in the `session` event's `sidecars` field.
  """
  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    port = Application.get_env(:manifold, :web_port, 4000)

    children = [
      # Start Prolog first: conversations depend on the KB server being up.
      Manifold.Prolog.Server,
      Manifold.Llama.Server,
      {Registry, keys: :unique, name: Manifold.Conversation.Registry},
      {DynamicSupervisor, name: Manifold.Conversation.Supervisor, strategy: :one_for_one},
      {Bandit, plug: Manifold.Web.Router, scheme: :http, port: port}
    ]

    Logger.info("[web] listening on http://127.0.0.1:#{port} (ws://127.0.0.1:#{port}/socket)")

    opts = [strategy: :one_for_one, name: Manifold.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
