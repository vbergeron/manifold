defmodule Manifold.Model do
  @moduledoc """
  The seam between the turn loop and whatever actually generates text.

  `Manifold.Turn` and `Manifold.Gate` call `completion/2` and `stream/3` here
  instead of reaching for `Manifold.Llama.Client` directly. That indirection is
  the whole point of this module: it is what lets the configured backend change
  — local `llama.cpp` today, an external provider later (see the
  external-models issues) — without either caller knowing which one is live.

  A backend implements the behaviour below and is selected with

      config :manifold, model: Manifold.Llama.Client

  `Manifold.Llama.Client` remains the default and, for now, the only
  implementation. Swapping it for another module is the entire integration
  surface: nothing else in this module should ever grow provider-specific
  logic — that belongs in the implementation, not the seam.
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
  def impl, do: Application.get_env(:manifold, :model, Manifold.Llama.Client)

  @doc "Delegates to the configured backend's `completion/2`."
  @spec completion(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def completion(prompt, opts \\ []), do: impl().completion(prompt, opts)

  @doc "Delegates to the configured backend's `stream/3`."
  @spec stream(String.t(), keyword(), (String.t() -> any())) :: {:ok, String.t()} | {:error, term()}
  def stream(prompt, opts, on_delta), do: impl().stream(prompt, opts, on_delta)
end
