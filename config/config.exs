import Config

# Defaults; overridden at boot by config/runtime.exs from MANIFOLD_* env vars
# (which mise.toml sets under [env]).
config :manifold,
  llama_host: "127.0.0.1",
  llama_port: 8080,
  prolog_host: "127.0.0.1",
  prolog_port: 8090,
  model_path: Path.expand("models/model.gguf", File.cwd!()),
  # Bandit endpoint: HTTP + the /socket WebSocket upgrade the UI connects to.
  web_port: 4000

config :logger, level: :info
