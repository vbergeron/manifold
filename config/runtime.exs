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
  # The `Manifold.Model` backend, provider-selected. `MANIFOLD_MODEL_PROVIDER` names
  # *which* branch is live; each branch reads its own env vars into that branch's opts,
  # because a local GGUF and a hosted API share no config shape (see `config/config.exs`
  # for why `:model` is `{module, opts}` rather than a flat bag of keys). Local hosting
  # ("llama") is not the implicit default with everything else bolted on — it is simply
  # the one provider with a `Manifold.Model` implementation in this codebase today, so it
  # is the one `known_providers` can actually resolve.
  known_providers = %{"llama" => Manifold.Llama.Client}
  provider = System.get_env("MANIFOLD_MODEL_PROVIDER", "llama")

  module =
    Map.get(known_providers, provider) ||
      raise """
      MANIFOLD_MODEL_PROVIDER=#{provider} has no Manifold.Model implementation in this \
      codebase yet (known: #{known_providers |> Map.keys() |> Enum.join(", ")}). Selecting \
      it is a boot-time error rather than a silent fall back to "llama", because a shell \
      that set MANIFOLD_API_KEY expecting an external provider to use it must find out its \
      credentials went unused, not discover it turn by turn. See \
      docs/adr/0001-external-model-decoding-strategy.md for what lands next.
      """

  # `put_opt` only touches a key an operator actually set, so an unset env var leaves
  # `config/config.exs`'s (or, for a provider with no compiled-in defaults, an empty)
  # opts alone rather than clobbering it with `nil`.
  put_opt = fn
    opts, _key, nil -> opts
    opts, key, value -> Keyword.put(opts, key, value)
  end

  {_default_module, default_opts} = Application.get_env(:manifold, :model)
  base_opts = if provider == "llama", do: default_opts, else: []

  llama_port = System.get_env("MANIFOLD_LLAMA_PORT")

  model_opts =
    case provider do
      "llama" ->
        # `MANIFOLD_MODEL` keeps meaning exactly what it always has: a path to a GGUF
        # file. Provider selection is additive on top of it, not a replacement for it.
        base_opts
        |> put_opt.(:model_path, System.get_env("MANIFOLD_MODEL"))
        |> put_opt.(:llama_host, System.get_env("MANIFOLD_LLAMA_HOST"))
        |> put_opt.(:llama_port, llama_port && String.to_integer(llama_port))

      _external ->
        # No provider reaches this branch today (`known_providers` only has "llama"), but
        # the env vars are wired ahead of one landing so a future backend's opts don't
        # need another runtime.exs change — only a `known_providers` entry.
        base_opts
        |> put_opt.(:api_key, System.get_env("MANIFOLD_API_KEY"))
        |> put_opt.(:model, System.get_env("MANIFOLD_MODEL_NAME"))
    end

  config :manifold, model: {module, model_opts}

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
