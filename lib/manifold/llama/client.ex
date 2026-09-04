defmodule Manifold.Llama.Client do
  @moduledoc """
  HTTP client for the supervised `llama.cpp` server.

  The whole point of manifold's LLM layer is here: `completion/2` accepts a
  `:grammar` option carrying a **GBNF** string, which llama.cpp uses to
  *constrain decoding*. Passing `Manifold.Grammar.prolog/0` makes the model
  physically unable to emit anything but syntactically valid Prolog — the
  guarantee Ollama's JSON-schema-only API could not give us.

  Implements `Manifold.Model` — the default backend, selected there unless
  `config :manifold, :model` names another one. Its own opts (`model_path`,
  `llama_host`, `llama_port`) travel alongside it in that same `{module, opts}` tuple —
  see `Manifold.Model`'s moduledoc.
  """
  @behaviour Manifold.Model

  @receive_timeout 120_000

  @doc """
  Send a completion request. Options:

    * `:grammar`     — GBNF string; constrains output (default: none)
    * `:n_predict`   — max tokens (default 512)
    * `:temperature` — sampling temperature (default 0.7)

  Returns `{:ok, text}` or `{:error, reason}`.
  """
  @impl Manifold.Model
  @spec completion(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def completion(prompt, opts \\ []) do
    case Req.post(url(), json: body(prompt, opts), receive_timeout: @receive_timeout, retry: false) do
      {:ok, %{status: 200, body: %{"content" => content}}} -> {:ok, content}
      {:ok, %{status: status, body: body}} -> {:error, {:http, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Stream a completion, invoking `on_delta` with each token's text as it arrives.
  Same options as `completion/2`; returns `{:ok, full_text}` (every delta
  concatenated) so the caller can persist the finished message.

  llama.cpp answers `stream: true` with SSE — one `data: {…}` line per token,
  each carrying a `content` delta, the last one `"stop": true`. Chunk boundaries
  fall wherever TCP puts them, so the unterminated tail of each chunk is carried
  over in the response's private storage until its newline arrives.

  Aborting is by killing the calling process: the request is owned by whoever
  calls this, so its death closes the connection and llama.cpp stops generating.
  That is exactly what `cancel_turn` does.
  """
  @impl Manifold.Model
  @spec stream(String.t(), keyword(), (String.t() -> any())) :: {:ok, String.t()} | {:error, term()}
  def stream(prompt, opts, on_delta) when is_function(on_delta, 1) do
    body = Map.put(body(prompt, opts), :stream, true)
    collector = fn {:data, data}, {req, resp} -> {:cont, {req, absorb(resp, data, on_delta)}} end

    case Req.post(url(), json: body, into: collector, receive_timeout: @receive_timeout, retry: false) do
      {:ok, %{status: 200} = resp} -> {:ok, streamed_text(resp)}
      {:ok, %{status: status} = resp} -> {:error, {:http, status, streamed_text(resp)}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp url do
    {host, port} = Manifold.Llama.Server.endpoint()
    "http://#{host}:#{port}/completion"
  end

  defp body(prompt, opts) do
    %{
      prompt: prompt,
      n_predict: Keyword.get(opts, :n_predict, 512),
      temperature: Keyword.get(opts, :temperature, 0.7),
      cache_prompt: true
    }
    |> maybe_put(:grammar, opts[:grammar])
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # --- SSE accumulation ------------------------------------------------------

  defp absorb(resp, data, on_delta) do
    {lines, tail} = split_lines(Req.Response.get_private(resp, :buffer, "") <> data)

    text =
      Enum.reduce(lines, streamed_text(resp), fn line, acc ->
        case delta(line) do
          "" ->
            acc

          chunk ->
            on_delta.(chunk)
            acc <> chunk
        end
      end)

    resp
    |> Req.Response.put_private(:buffer, tail)
    |> Req.Response.put_private(:text, text)
  end

  defp split_lines(buffer) do
    {tail, lines} = buffer |> String.split("\n") |> List.pop_at(-1)
    {lines, tail}
  end

  defp delta("data: " <> json) do
    case Jason.decode(json) do
      {:ok, %{"content" => content}} when is_binary(content) -> content
      _ -> ""
    end
  end

  defp delta(_line), do: ""

  defp streamed_text(resp), do: Req.Response.get_private(resp, :text, "")
end
