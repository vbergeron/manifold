import Config

# Defaults; overridden at boot by config/runtime.exs from MANIFOLD_* env vars
# (which mise.toml sets under [env]).
config :manifold,
  llama_host: "127.0.0.1",
  llama_port: 8080,
  # No prolog host/port: each conversation launches its own swipl and MQI assigns it a
  # free loopback port, which it reports on stdout. A fixed port could not work for N
  # engines, so there is deliberately nothing to configure.
  model_path: Path.expand("models/model.gguf", File.cwd!()),
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
  conversation_idle_ms: 900_000

config :logger, level: :info

# Per-environment overrides. Without this the whole of `config/test.exs` would be ignored.
import_config "#{config_env()}.exs"
