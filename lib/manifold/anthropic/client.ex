defmodule Manifold.Anthropic.Client do
  @moduledoc """
  HTTP client for Anthropic's Messages API (`POST /v1/messages`).

  Implements `Manifold.Model` — the first external backend, alongside the local
  `Manifold.Llama.Client`. Selecting it is `config :manifold, model:
  {Manifold.Anthropic.Client, opts}`; wiring that into `MANIFOLD_MODEL_PROVIDER`
  (`config/runtime.exs`'s `known_providers`) is config plumbing left to a
  follow-up, per #12's own scope.

  ## Config vs. call opts

  Two different `opts` exist here, and they are not interchangeable — the same
  split `Manifold.Llama.Client`/`Manifold.Llama.Server` already make between
  `Manifold.Model.opts/0` and a call's own `opts` argument:

    * **Backend config**, read once per call from `Manifold.Model.opts/0`:
      `:api_key` and `:model` (both required — a request without either fails
      fast as `{:error, {:missing_config, key}}` rather than reaching for a
      network call that can only 401), plus optional `:base_url` (default
      `"https://api.anthropic.com"`, override for a proxy or a test double),
      `:receive_timeout`, and `:plug` (a `Req` test seam — see the test suite —
      never set in real config).
    * **Per-call generation opts**, the `opts` argument `completion/2`/`stream/3`
      receive directly: `:n_predict` (→ `max_tokens`, default 512) and
      `:temperature` (default 0.7), same defaults as `Llama.Client` for a
      backend swap to change as little else as possible. `:system`, `:tools`
      and `:tool_choice` pass straight through to the request body when
      present — this is the seam the constrained-decoding decision
      (`docs/adr/0001-external-model-decoding-strategy.md`) reaches for
      without this module deciding anything about *how* they get used.

  `:grammar` — the one option every caller in this codebase currently threads
  through `Manifold.Model.completion/2` — is silently ignored here on purpose.
  There is no Anthropic primitive for arbitrary GBNF (that is the entire
  premise of the ADR above); `Manifold.Model`'s own contract says a backend
  that cannot constrain decoding is free to ignore it rather than error, so
  this client carries no syntax guarantee at all today. It does not implement
  the ADR's retry-validated tier either — that lands with the constrained-
  decoding follow-up, not here.

  Auth is a header (`x-api-key`), never a query param or path segment, per
  Anthropic's API and this issue's explicit requirement.
  """
  @behaviour Manifold.Model

  @base_url "https://api.anthropic.com"
  @anthropic_version "2023-06-01"
  # Independent of Llama.Client's 120s (tuned for a local process with no
  # network hop). A hosted API adds real network latency on top of inference,
  # but Req/Finch resets this timeout on each chunk received rather than
  # timing the whole request, so it does not need to cover a full generation —
  # only the gap between two chunks. Override per-deployment via the backend
  # config's `:receive_timeout` if a slower network needs more.
  @receive_timeout 60_000

  @doc """
  Send a completion request. Returns `{:ok, text}` — every `"text"` content
  block in the response, concatenated — or `{:error, reason}`.

  A response can also carry other block types (e.g. `"tool_use"`, once a
  caller opts into `:tools`); this function surfaces only prose, since
  `completion/2`'s contract is plain text. A caller that needs the rest of the
  response is not this call site's problem to solve — see the moduledoc.
  """
  @impl Manifold.Model
  @spec completion(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def completion(prompt, opts \\ []) do
    config = Manifold.Model.opts()

    with {:ok, api_key} <- fetch(config, :api_key),
         {:ok, model} <- fetch(config, :model) do
      request_opts = request_opts(config, api_key, body(prompt, opts, model, false))

      case Req.post(url(config), request_opts) do
        {:ok, %{status: 200, body: body}} -> {:ok, text(body)}
        {:ok, %{body: body} = resp} -> {:error, map_error(resp, body)}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc """
  Stream a completion, invoking `on_delta` with each text chunk as it arrives.
  Same opts as `completion/2`; returns `{:ok, full_text}` on a clean finish.

  Anthropic answers `stream: true` with SSE, but unlike llama.cpp's one-shape-
  per-line stream, each line's `data:` JSON carries a `type` that disambiguates
  a dozen event kinds — `message_start`, `content_block_start`, `ping`,
  `message_delta`, `message_stop`, and so on. Only `content_block_delta` with a
  `text_delta` inner type carries prose; everything else is structural
  bookkeeping this client has no use for and ignores. A stream can also emit
  `type: "error"` **after** the initial 200 — e.g. `overloaded_error` mid-
  generation — which is why this cannot just trust the opening status the way
  a non-streaming response can; `absorb/3` watches for it across every chunk
  and `stream/3` checks for it once the body is exhausted.

  Aborting is the same story as `Llama.Client`: killing the calling process
  closes the connection and Anthropic stops billing/generating tokens for it.
  """
  @impl Manifold.Model
  @spec stream(String.t(), keyword(), (String.t() -> any())) :: {:ok, String.t()} | {:error, term()}
  def stream(prompt, opts, on_delta) when is_function(on_delta, 1) do
    config = Manifold.Model.opts()

    with {:ok, api_key} <- fetch(config, :api_key),
         {:ok, model} <- fetch(config, :model) do
      collector = fn {:data, data}, {req, resp} -> {:cont, {req, absorb(resp, data, on_delta)}} end
      body = body(prompt, opts, model, true)
      request_opts = config |> request_opts(api_key, body) |> Keyword.put(:into, collector)

      case Req.post(url(config), request_opts) do
        {:ok, %{status: 200} = resp} ->
          case Req.Response.get_private(resp, :stream_error) do
            nil -> {:ok, streamed_text(resp)}
            error -> {:error, error}
          end

        {:ok, resp} ->
          {:error, map_error(resp, raw_body(resp))}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # --- config / request building ----------------------------------------------

  defp fetch(config, key) do
    case Keyword.get(config, key) do
      nil -> {:error, {:missing_config, key}}
      value -> {:ok, value}
    end
  end

  defp url(config), do: Keyword.get(config, :base_url, @base_url) <> "/v1/messages"

  defp request_opts(config, api_key, body) do
    [
      json: body,
      headers: [{"x-api-key", api_key}, {"anthropic-version", @anthropic_version}],
      receive_timeout: Keyword.get(config, :receive_timeout, @receive_timeout),
      retry: false
    ]
    |> maybe_put_plug(config[:plug])
  end

  # `:plug` swaps Req's real transport for `Req.Test`'s — the seam that keeps
  # this client's tests hermetic (no network call, no OS process; see
  # `test/manifold/anthropic/client_test.exs`). Never set outside a test.
  defp maybe_put_plug(opts, nil), do: opts
  defp maybe_put_plug(opts, plug), do: Keyword.put(opts, :plug, plug)

  defp body(prompt, opts, model, stream?) do
    %{
      model: model,
      max_tokens: Keyword.get(opts, :n_predict, 512),
      temperature: Keyword.get(opts, :temperature, 0.7),
      messages: [%{role: "user", content: prompt}],
      stream: stream?
    }
    |> maybe_put(:system, opts[:system])
    |> maybe_put(:tools, opts[:tools])
    |> maybe_put(:tool_choice, opts[:tool_choice])
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # --- response mapping (non-streaming) ---------------------------------------

  defp text(%{"content" => blocks}) when is_list(blocks) do
    blocks
    |> Enum.filter(&(&1["type"] == "text"))
    |> Enum.map_join("", & &1["text"])
  end

  defp text(_body), do: ""

  # Shared between `completion/2`'s already-decoded JSON body and `stream/3`'s
  # `raw_body/1` (best-effort decode of whatever arrived before an error
  # status), so a 429 or a `{"error": {...}}` payload maps the same way
  # regardless of which call site saw it.
  defp map_error(%{status: 429} = resp, _body), do: {:rate_limited, retry_after(resp)}

  defp map_error(%{status: status}, %{"error" => %{"type" => type, "message" => message}}),
    do: {:api_error, status, type, message}

  defp map_error(%{status: status}, body), do: {:http, status, body}

  defp retry_after(resp) do
    with [value] <- Req.Response.get_header(resp, "retry-after"),
         {seconds, _} <- Integer.parse(value) do
      seconds
    else
      _ -> nil
    end
  end

  # --- SSE accumulation (streaming) -------------------------------------------

  defp absorb(resp, data, on_delta) do
    {lines, tail} = split_lines(Req.Response.get_private(resp, :buffer, "") <> data)
    error = Req.Response.get_private(resp, :stream_error)

    {text, error} =
      Enum.reduce(lines, {streamed_text(resp), error}, fn line, {text, error} ->
        case sse_event(line) do
          {:delta, chunk} ->
            on_delta.(chunk)
            {text <> chunk, error}

          {:error, reason} ->
            {text, error || reason}

          :ignore ->
            {text, error}
        end
      end)

    resp
    |> Req.Response.put_private(:buffer, tail)
    |> Req.Response.put_private(:text, text)
    |> Req.Response.put_private(:stream_error, error)
    # Kept alongside the parsed `:text` purely so a non-200 status hit mid-`into:`
    # (Req never runs the normal JSON step once `into:` diverts the body) still has
    # something to decode in `raw_body/1` — an error body is a plain JSON object,
    # not SSE, so `sse_event/1` above would otherwise just discard it as `:ignore`.
    |> Req.Response.put_private(:raw, Req.Response.get_private(resp, :raw, "") <> data)
  end

  defp split_lines(buffer) do
    {tail, lines} = buffer |> String.split("\n") |> List.pop_at(-1)
    {lines, tail}
  end

  defp sse_event("data: " <> json) do
    case Jason.decode(json) do
      {:ok, %{"type" => "content_block_delta", "delta" => %{"type" => "text_delta", "text" => text}}} ->
        {:delta, text}

      {:ok, %{"type" => "error", "error" => %{"type" => type, "message" => message}}} ->
        {:error, {:api_error, nil, type, message}}

      _ ->
        :ignore
    end
  end

  defp sse_event(_line), do: :ignore

  defp streamed_text(resp), do: Req.Response.get_private(resp, :text, "")

  defp raw_body(resp) do
    raw = Req.Response.get_private(resp, :raw, "")

    case Jason.decode(raw) do
      {:ok, decoded} -> decoded
      _ -> raw
    end
  end
end
