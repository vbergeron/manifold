import Config

# Defaults; overridden at boot by config/runtime.exs from MANIFOLD_* env vars
# (which mise.toml sets under [env]).
config :manifold,
  # The `Manifold.Model` backend the turn loop generates through, as `{module, opts}` —
  # opts are backend-specific, which is the whole point: a local GGUF needs a filesystem
  # path and a sidecar host/port, an external provider needs an API key and a model name,
  # and neither shape leaks into the other. Swapping the module is the entire integration
  # point for another backend (see the external-models issues); nothing else should need
  # to change to add one, only to select it and give it its own opts. Local hosting is one
  # branch among equals here, not an implicit default with external bolted on — see
  # `config/runtime.exs` for how `MANIFOLD_MODEL_PROVIDER` picks between them.
  model: {
    Manifold.Llama.Client,
    # No prolog host/port: each conversation launches its own swipl and MQI assigns it a
    # free loopback port, which it reports on stdout. A fixed port could not work for N
    # engines, so there is deliberately nothing to configure.
    model_path: Path.expand("models/model.gguf", File.cwd!()),
    llama_host: "127.0.0.1",
    llama_port: 8080
  },
  # Bandit endpoint: HTTP + the /socket WebSocket upgrade the UI connects to.
  web_port: 4000,
  # Live conversations, each holding one swipl (~5.3 MB PSS, ~90 ms to boot). Nothing
  # scarce is binding at this number — 64 engines is ~340 MB, 256 fds and ~320 threads
  # against limits of 1048576 and 126523. It is chosen so a full boot storm stays
  # sub-second and the blast radius stays legible. Note it does NOT bound load:
  # llama-server runs with n_parallel=1, so turns serialise across all conversations.
  max_conversations: 64,
  # Idle conversations are evicted and rehydrated from their log on next open. Must stay
  # well above the socket's own 95 s idle deadline so socket churn never evicts.
  conversation_idle_ms: 900_000,
  # `nil` disables it. A path here is `consult/1`ed into every conversation's engine —
  # once per engine, since each one is a fresh swipl — before anything else touches it,
  # so predicates and rules it defines are available from the first assert or query. See
  # `Manifold.Conversation.init/1`.
  prelude_path: nil

config :logger, level: :info

# Per-environment overrides. Without this the whole of `config/test.exs` would be ignored.
import_config "#{config_env()}.exs"
