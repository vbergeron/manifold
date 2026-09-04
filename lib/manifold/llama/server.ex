defmodule Manifold.Llama.Server do
  @moduledoc """
  Supervised `llama.cpp` HTTP server, running as an independent OS process.

  Owns the `llama-server` child through a `Port`, polls `/health` until the
  model has loaded, and SIGTERMs the child on shutdown. If no model file is
  present it parks in the `:no_model` state instead of crash-looping the
  supervisor — drop a `.gguf` in place and restart.
  """
  use GenServer
  require Logger

  alias Manifold.OsProcess

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "True once the model is loaded and the HTTP server answers /health."
  def ready?, do: GenServer.call(__MODULE__, :ready?)

  @doc "`{host, port}` of the running server."
  def endpoint, do: GenServer.call(__MODULE__, :endpoint)

  @impl true
  def init(_opts) do
    Process.flag(:trap_exit, true)
    {host, port, model} = llama_config()

    state = %{
      status: :init,
      port_ref: nil,
      os_pid: nil,
      host: host,
      http_port: port,
      model: model
    }

    if model && File.exists?(model) do
      args = [
        "--model",
        model,
        "--host",
        host,
        "--port",
        Integer.to_string(port),
        "--jinja",
        "--ctx-size",
        "8192",
        # Lock model pages in RAM so they are never swapped back after the
        # warm-up inference pages them in. Requires sufficient ulimit -l;
        # remove if the process lacks the privilege.
        "--mlock"
      ]

      case OsProcess.open("llama-server", args) do
        {:ok, ref, os_pid} ->
          Logger.info("[llama] launching llama-server pid=#{os_pid} on http://#{host}:#{port}")
          Process.send_after(self(), :poll_ready, 1_000)
          {:ok, %{state | status: :starting, port_ref: ref, os_pid: os_pid}}

        {:error, reason} ->
          {:stop, reason}
      end
    else
      Logger.warning(no_model_message(model))
      {:ok, %{state | status: :no_model}}
    end
  end

  @impl true
  def handle_call(:ready?, _from, s), do: {:reply, s.status == :ready, s}
  def handle_call(:endpoint, _from, s), do: {:reply, {s.host, s.http_port}, s}

  @impl true
  def handle_info(:poll_ready, s) do
    if healthy?(s.host, s.http_port) do
      Logger.info("[llama] ready on http://#{s.host}:#{s.http_port}")
      send(self(), :warmup)
      {:noreply, %{s | status: :ready}}
    else
      Process.send_after(self(), :poll_ready, 1_000)
      {:noreply, s}
    end
  end

  # Fire a minimal 1-token completion to page the model weights into RAM.
  # The server is already :ready so real requests can proceed in parallel;
  # this just ensures the first user turn does not eat the page-fault storm.
  def handle_info(:warmup, s) do
    Logger.info("[llama] warming up — paging model weights into memory")

    Task.start(fn ->
      prompt = "<|im_start|>user\nhi<|im_end|>\n<|im_start|>assistant\n"

      case Manifold.Llama.Client.completion(prompt, n_predict: 1, temperature: 0.0) do
        {:ok, _} ->
          Logger.info("[llama] warm — first-inference cost paid at startup")

        {:error, reason} ->
          Logger.warning("[llama] warmup failed (not fatal): #{inspect(reason)}")
      end
    end)

    {:noreply, s}
  end

  # llama-server log lines arrive on the port; forward at debug.
  def handle_info({ref, {:data, data}}, %{port_ref: ref} = s) do
    Logger.debug(["[llama] ", String.trim_trailing(data)])
    {:noreply, s}
  end

  # The child died — crash so the supervisor restarts us (independently of Prolog).
  def handle_info({ref, {:exit_status, code}}, %{port_ref: ref} = s) do
    {:stop, {:llama_server_exited, code}, s}
  end

  def handle_info(_msg, s), do: {:noreply, s}

  @impl true
  def terminate(_reason, s) do
    OsProcess.kill(s.os_pid)
    :ok
  end

  defp healthy?(host, port) do
    case Req.get("http://#{host}:#{port}/health", retry: false, receive_timeout: 800) do
      {:ok, %{status: 200}} -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  # This sidecar exists to serve `Manifold.Llama.Client`, so its own config lives under
  # `Manifold.Model.opts/0` when that is the configured backend — same provider-aware
  # `:model` config every other reader of these opts uses (see `Manifold.Model`). When a
  # different backend is configured there is no GGUF to serve; this parks in `:no_model`
  # exactly as it would for a missing file, rather than guessing at a host/port that
  # belong to a provider this server has no part in.
  defp llama_config do
    case Manifold.Model.impl() do
      Manifold.Llama.Client ->
        opts = Manifold.Model.opts()
        {Keyword.get(opts, :llama_host, "127.0.0.1"), Keyword.get(opts, :llama_port, 8080), opts[:model_path]}

      _other ->
        {"127.0.0.1", 8080, nil}
    end
  end

  defp no_model_message(nil) do
    "[llama] no local model configured — server NOT started. Set MANIFOLD_MODEL_PROVIDER=llama " <>
      "and MANIFOLD_MODEL, or drop a .gguf at the configured model_path, and restart."
  end

  defp no_model_message(model) do
    "[llama] no model at #{model} — server NOT started. Put a .gguf there (or set MANIFOLD_MODEL) and restart."
  end
end
