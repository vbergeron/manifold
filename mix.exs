defmodule Manifold.MixProject do
  use Mix.Project

  def project do
    [
      app: :manifold,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Manifold.Application boots the supervision tree that owns the two sidecar
  # servers (llama.cpp + swipl MQI) as independent, supervised OS processes.
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
