defmodule Manifold.MixProject do
  use Mix.Project

  def project do
    [
      app: :manifold,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps()
    ]
  end

  # `test/support` holds harness code that tests compile against — a WebSocket client, a
  # fake MQI server, a case template — so it must be compiled, but only under `:test`.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Manifold.Application boots the supervision tree: the shared llama.cpp sidecar, the
  # conversation registry and supervisor, and the endpoint. Prolog is not here — each
  # conversation owns its own swipl (`Manifold.Prolog.Engine`).
  #
  # This is unconditional, so `mix test` boots the app too. That is intentional: the
  # integration tier needs the registry and the conversation supervisor, and
  # `config/test.exs` makes booting harmless (port 4001, no store writes, no model).
  def application do
    [
      extra_applications: [:logger, :crypto],
      mod: {Manifold.Application, []}
    ]
  end

  defp deps do
    [
      {:req, "~> 0.5"},
      {:jason, "~> 1.4"},
      # The web half: Bandit serves the UI socket, websock_adapter does the
      # upgrade. Plug arrives through Bandit anyway, but `Manifold.Web.Router`
      # uses `Plug.Router` and `Plug.Static` directly, so it is named directly.
      {:bandit, "~> 1.0"},
      {:websock_adapter, "~> 0.5"},
      {:plug, "~> 1.20"}
    ]
  end
end
