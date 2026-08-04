import Config

# Read the sidecar wiring from the environment at boot. mise.toml [env] sets
# sensible defaults; override per-shell as needed.
if model = System.get_env("MANIFOLD_MODEL") do
  config :manifold, model_path: model
end

if port = System.get_env("MANIFOLD_LLAMA_PORT") do
  config :manifold, llama_port: String.to_integer(port)
end

if max = System.get_env("MANIFOLD_MAX_CONVERSATIONS") do
  config :manifold, max_conversations: String.to_integer(max)
end

if idle = System.get_env("MANIFOLD_CONVERSATION_IDLE_MS") do
  config :manifold, conversation_idle_ms: String.to_integer(idle)
end

if port = System.get_env("MANIFOLD_WEB_PORT") do
  config :manifold, web_port: String.to_integer(port)
end

# Conversation persistence. `MANIFOLD_DATA_DIR=off` disables it (every conversation
# becomes ephemeral); anything else is the directory the append-only logs live in.
# See `Manifold.Store` for the adapter contract.
case System.get_env("MANIFOLD_DATA_DIR") do
  nil -> :ok
  "off" -> config :manifold, store: Manifold.Store.None
  dir -> config :manifold, store: {Manifold.Store.Log, dir: dir}
end
