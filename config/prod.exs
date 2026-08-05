import Config

# Deliberately empty. Everything that differs in production — the model path, ports, the
# data directory, capacity — is read from the environment at boot in `config/runtime.exs`,
# which is where deployment configuration belongs. This file exists because
# `import_config "#{config_env()}.exs"` requires one per environment.
