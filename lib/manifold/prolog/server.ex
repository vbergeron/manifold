defmodule Manifold.Prolog.Server do
  @moduledoc """
  Supervised SWI-Prolog **Machine Query Interface** (MQI) server, running as an
  independent OS process.

  Launches `swipl mqi --port=<p> --password=<generated>` through a `Port`, waits
  until the socket accepts connections, and SIGTERMs it on shutdown. Each MQI
  *connection* is a separate Prolog engine — so one conversation == one
  connection (see `Manifold.Conversation`).

  Crucially, this is our runaway-query kill switch: a non-terminating goal can be
  bounded per-query (MQI timeout) and, worst case, the whole engine can be killed
  by restarting this supervised process — something an in-process embedding
  cannot safely do.
  """
  use GenServer
  require Logger

  alias Manifold.OsProcess

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "True once the MQI socket accepts connections."
  def ready?, do: GenServer.call(__MODULE__, :ready?)

  @doc "`%{host, port, password}` needed to open an MQI connection."
  def connection, do: GenServer.call(__MODULE__, :connection)

  @impl true
  def init(_opts) do
    Process.flag(:trap_exit, true)
    cfg = Application.get_all_env(:manifold)
    host = cfg[:prolog_host]
    port = cfg[:prolog_port]
    password = Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)

    # Run MQI's accept loop on the *main* thread (run_server_on_thread(false)) so
    # swipl blocks here and the process stays alive. The `mqi` CLI subcommand
    # starts the server on a background thread and then halts — no good for a
    # long-lived supervised sidecar.
    goal =
      "use_module(library(mqi)), " <>
        "mqi_start([port(#{port}), password('#{password}'), run_server_on_thread(false)])"

    args = ["-q", "-g", goal, "-t", "halt"]

    case OsProcess.open("swipl", args) do
      {:ok, ref, os_pid} ->
        Logger.info("[prolog] launching swipl MQI pid=#{os_pid} on #{host}:#{port}")
        Process.send_after(self(), :poll_ready, 300)

        {:ok,
         %{
           status: :starting,
           port_ref: ref,
           os_pid: os_pid,
           host: host,
           mqi_port: port,
           password: password
         }}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call(:ready?, _from, s), do: {:reply, s.status == :ready, s}

  def handle_call(:connection, _from, s) do
    {:reply, %{host: s.host, port: s.mqi_port, password: s.password}, s}
  end

  @impl true
  def handle_info(:poll_ready, s) do
    if listening?(s.host, s.mqi_port) do
      Logger.info("[prolog] MQI ready on #{s.host}:#{s.mqi_port}")
      {:noreply, %{s | status: :ready}}
    else
      Process.send_after(self(), :poll_ready, 300)
      {:noreply, s}
    end
  end

  def handle_info({ref, {:data, data}}, %{port_ref: ref} = s) do
    Logger.debug(["[prolog] ", String.trim_trailing(data)])
    {:noreply, s}
  end

  def handle_info({ref, {:exit_status, code}}, %{port_ref: ref} = s) do
    {:stop, {:swipl_mqi_exited, code}, s}
  end

  def handle_info(_msg, s), do: {:noreply, s}

  @impl true
  def terminate(_reason, s) do
    OsProcess.kill(s.os_pid)
    :ok
  end

  defp listening?(host, port) do
    case :gen_tcp.connect(String.to_charlist(host), port, [:binary, active: false], 500) do
      {:ok, sock} ->
        :gen_tcp.close(sock)
        true

      _ ->
        false
    end
  end
end
