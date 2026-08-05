import Config

# Read the sidecar wiring from the environment at boot. mise.toml [env] sets sensible
# defaults; override per-shell as needed.
#
# Skipped entirely under `:test`. This file runs *after* `config/test.exs`, so without the
# guard a developer's shell would silently override the test configuration —
# `mise.toml [env]` sets `MANIFOLD_MODEL`, which would drag the real model into a test run
# and make results depend on whose machine they ran on. Tests take their configuration
# from `config/test.exs` and nowhere else.
if config_env() != :test do
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

  # A Prolog file `consult/1`ed into every conversation's engine at boot, ahead of
  # replay — the natural place for background rules and facts that should not have to
  # be re-asserted (or re-taught to the model) in every conversation. Unset by default.
  if prelude = System.get_env("MANIFOLD_PRELUDE") do
    config :manifold, prelude_path: prelude
  end

  # Conversation persistence. `MANIFOLD_DATA_DIR=off` disables it (every conversation
  # becomes ephemeral); anything else is the directory the append-only logs live in.
  # See `Manifold.Store` for the adapter contract.
  case System.get_env("MANIFOLD_DATA_DIR") do
    nil -> :ok
    "off" -> config :manifold, store: Manifold.Store.None
    dir -> config :manifold, store: {Manifold.Store.Log, dir: dir}
  end
end
