defmodule Manifold.Model do
  @moduledoc """
  The seam between the turn loop and whatever actually generates text.

  `Manifold.Turn` and `Manifold.Gate` call `completion/2` and `stream/3` here
  instead of reaching for `Manifold.Llama.Client` directly. That indirection is
  the whole point of this module: it is what lets the configured backend change
  — local `llama.cpp` today, an external provider later (see the
  external-models issues) — without either caller knowing which one is live.

  A backend implements the behaviour below and is selected with

      config :manifold, model: {Manifold.Llama.Client, model_path: "...", llama_host: "...", llama_port: 8080}

  i.e. `{module, opts}` — `opts` is backend-specific and opaque to this module on
  purpose: a local GGUF backend needs a filesystem path and a sidecar host/port, an
  external provider needs an API key and a model name, and this seam never grows an
  opinion about either shape. See `config/config.exs` and `config/runtime.exs` (the
  latter is where `MANIFOLD_MODEL_PROVIDER` picks the module and each provider's own
  env vars fill in its opts).

  `Manifold.Llama.Client` remains the default. `Manifold.Anthropic.Client` is
  the first external implementation — it exists and can be named directly in
  `config :manifold, :model`, but wiring it into `MANIFOLD_MODEL_PROVIDER`
  (`config/runtime.exs`'s `known_providers`) is config plumbing left to a
  follow-up, deliberately out of scope for landing the client itself. Swapping
  the configured module is the entire integration surface: nothing else in
  this module should ever grow provider-specific logic — that belongs in the
  implementation, not the seam.
  """

  @doc """
  Send a completion request. Returns `{:ok, text}` or `{:error, reason}`.

  Options are backend-specific beyond the two every caller in this codebase
  currently relies on: `:n_predict` (max tokens) and `:temperature`. A
  grammar-constrained backend also accepts `:grammar` (a GBNF string); a
  backend that cannot constrain decoding is free to ignore it.
  """
  @callback completion(prompt :: String.t(), opts :: keyword()) ::
              {:ok, String.t()} | {:error, term()}

  @doc """
  Stream a completion, invoking `on_delta` with each chunk of text as it
  arrives. Returns `{:ok, full_text}` (every delta concatenated) so the caller
  can persist the finished message once streaming ends.
  """
  @callback stream(prompt :: String.t(), opts :: keyword(), on_delta :: (String.t() -> any())) ::
              {:ok, String.t()} | {:error, term()}

  @doc "The configured backend module. Defaults to `Manifold.Llama.Client`."
  @spec impl() :: module()
  def impl, do: config() |> elem(0)

  @doc """
  The configured backend's own opts — the `model_path`/`llama_host`/`llama_port` a local
  backend needs, the `api_key`/`model` an external one needs, whatever the next one
  needs. Only the backend named by `impl/0` is expected to know what these mean;
  `Manifold.Llama.Server` is the one other reader in this codebase, and only because it
  is `Manifold.Llama.Client`'s sidecar.
  """
  @spec opts() :: keyword()
  def opts, do: config() |> elem(1)

  # `Application.get_env(:manifold, :model)` is documented and configured as `{module,
  # opts}`, but a bare module atom is accepted too — the shape `test/manifold/model_test.exs`
  # and any ad-hoc `Application.put_env(:manifold, :model, Fake)` reach for when a test
  # cares about the backend and not its opts.
  defp config do
    case Application.get_env(:manifold, :model, Manifold.Llama.Client) do
      {module, opts} when is_atom(module) and is_list(opts) -> {module, opts}
      module when is_atom(module) -> {module, []}
    end
  end

  @doc "Delegates to the configured backend's `completion/2`."
  @spec completion(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def completion(prompt, opts \\ []), do: impl().completion(prompt, opts)

  @doc "Delegates to the configured backend's `stream/3`."
  @spec stream(String.t(), keyword(), (String.t() -> any())) :: {:ok, String.t()} | {:error, term()}
  def stream(prompt, opts, on_delta), do: impl().stream(prompt, opts, on_delta)
end
