import Config

# The test environment is deliberately hermetic: `config/runtime.exs` is skipped under
# `:test`, so nothing here can be overridden by a developer's shell.
config :manifold,
  # Never collide with a dev server on 4000. `mix test` starts Bandit like any other
  # environment, because the integration tier wants the Registry and the conversation
  # supervisor anyway, and booting is harmless once the settings below are in place.
  web_port: 4001,

  # No conversation writes anything to the repo's `data/` directory. Tests that exercise
  # the log adapter pass an explicit `dir:` into a temporary directory instead, so the
  # suite leaves the working tree clean.
  store: Manifold.Store.None,

  # A path that does not exist, so `Manifold.Llama.Server` parks in `:no_model` and never
  # spawns `llama-server`. This is load-bearing rather than merely fast: in that state
  # `endpoint/0` still answers, so `Manifold.Llama.Client` returns a real `{:error, _}`
  # instead of exiting `:noproc` — which is what lets the no-model fallback path be tested
  # at all.
  model_path: "/nonexistent/manifold-test-no-model.gguf",

  # Long enough that idle eviction never fires by accident. Tests that want eviction set
  # it themselves with `Application.put_env` and restore it in `on_exit`.
  conversation_idle_ms: 900_000

# The suite is noisy at :info — every engine boot and conversation logs.
config :logger, level: :warning
