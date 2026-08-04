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
    cfg = Application.get_all_env(:manifold)
    host = cfg[:llama_host]
    port = cfg[:llama_port]
    model = cfg[:model_path]

    state = %{
      status: :init,
      port_ref: nil,
      os_pid: nil,
      host: host,
      http_port: port,
      model: model
    }

    if File.exists?(model) do
      args = [
        "--model",
        model,
        "--host",
        host,
        "--port",
        Integer.to_string(port),
        "--jinja",
        "--ctx-size",
        "8192"
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
      Logger.warning(
        "[llama] no model at #{model} — server NOT started. Put a .gguf there (or set MANIFOLD_MODEL) and restart."
      )

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
      {:noreply, %{s | status: :ready}}
    else
      Process.send_after(self(), :poll_ready, 1_000)
      {:noreply, s}
    end
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
end
