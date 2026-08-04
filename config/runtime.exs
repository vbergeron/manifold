import Config

# Read the sidecar wiring from the environment at boot. mise.toml [env] sets
# sensible defaults; override per-shell as needed.
if model = System.get_env("MANIFOLD_MODEL") do
  config :manifold, model_path: model
end

if port = System.get_env("MANIFOLD_LLAMA_PORT") do
  config :manifold, llama_port: String.to_integer(port)
end

if port = System.get_env("MANIFOLD_PROLOG_PORT") do
  config :manifold, prolog_port: String.to_integer(port)
end

if port = System.get_env("MANIFOLD_WEB_PORT") do
  config :manifold, web_port: String.to_integer(port)
end
