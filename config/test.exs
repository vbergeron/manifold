import Config

# The test environment is deliberately hermetic: `config/runtime.exs` is skipped under
# `:test`, so nothing here can be overridden by a developer's shell — including
# `MANIFOLD_MODEL_PROVIDER`, `MANIFOLD_API_KEY` and every other provider-selection or
# credential var runtime.exs reads. A shell configured to talk to a real external
# provider therefore cannot make a test suite dial out any more than one carrying
# `MANIFOLD_MODEL` can drag a real GGUF into a run. There is currently no external
# `Manifold.Model` implementation in this codebase to exercise (see
# `docs/adr/0001-external-model-decoding-strategy.md`); the day one lands, its test
# double belongs here, nested under `:model` exactly like `model_path` below — never a
# real API key.
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
  # at all. Nested under `:model` because `model_path` is `Manifold.Llama.Client`-specific
  # opts, not a codebase-wide setting — see `config/config.exs`. `llama_host`/`llama_port`
  # are carried too, matching `config/config.exs`'s shape exactly: `Llama.Server` never gets
  # far enough to dial them (parking on the missing `model_path` happens first), so they
  # cost nothing and keep the two configs' opts the same shape.
  model: {
    Manifold.Llama.Client,
    model_path: "/nonexistent/manifold-test-no-model.gguf",
    llama_host: "127.0.0.1",
    llama_port: 8080
  },

  # Long enough that idle eviction never fires by accident. Tests that want eviction set
  # it themselves with `Application.put_env` and restore it in `on_exit`.
  conversation_idle_ms: 900_000

# The suite is noisy at :info — every engine boot and conversation logs.
config :logger, level: :warning
